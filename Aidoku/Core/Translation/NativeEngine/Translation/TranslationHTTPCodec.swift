// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

enum TranslationHTTPCodec {
    static let maximumTranslationBytes = 512 * 1024

    static func requestBody(
        configuration: RemoteTranslationConfiguration,
        request: RemoteTranslationRequest
    ) throws -> Data {
        try request.validate()
        let translationData = try encodedTranslationData(request)
        let schema = responseSchema()
        let root: [String: Any]
        switch configuration.apiProtocol {
        case .responses:
            var responsesRoot: [String: Any] = [
                "model": configuration.model,
                "store": false,
                "instructions": configuration.instructions,
                "input": [[
                    "role": "user",
                    "content": [["type": "input_text", "text": translationData]],
                ]],
                "text": [
                    "format": [
                        "type": "json_schema",
                        "name": "translation_batch",
                        "strict": true,
                        "schema": schema,
                    ],
                ],
            ]
            if configuration.reasoningEffort != .modelDefault {
                responsesRoot["reasoning"] = [
                    "effort": configuration.reasoningEffort.rawValue,
                ]
            }
            root = responsesRoot
        case .chatCompletions:
            var chatRoot: [String: Any] = [
                "model": configuration.model,
                "store": false,
                "messages": [
                    [
                        "role": "system",
                        "content": configuration.instructions,
                    ],
                    [
                        "role": "user",
                        "content": translationData,
                    ],
                ],
                "temperature": 0,
                "response_format": [
                    "type": "json_schema",
                    "json_schema": [
                        "name": "translation_batch",
                        "strict": true,
                        "schema": schema,
                    ],
                ],
            ]
            if configuration.reasoningEffort != .modelDefault { chatRoot["reasoning_effort"] = configuration.reasoningEffort.rawValue }
            root = chatRoot
        }

        guard JSONSerialization.isValidJSONObject(root) else {
            throw RemoteTranslationError.invalidRequest(
                "translation payload cannot be represented as JSON"
            )
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func responseTranslations(
        from data: Data,
        protocol apiProtocol: RemoteTranslationProtocol,
        expectedSegmentIDs: [String]
    ) throws -> [RemoteTranslatedSegment] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RemoteTranslationError.invalidResponse(
                "response body is not valid JSON"
            )
        }
        guard let root = object as? [String: Any] else {
            throw RemoteTranslationError.invalidResponse(
                "response root must be a JSON object"
            )
        }

        let envelopeText: String
        switch apiProtocol {
        case .responses:
            envelopeText = try responsesEnvelopeText(root)
        case .chatCompletions:
            envelopeText = try chatCompletionsEnvelopeText(root)
        }
        return try parseTranslationEnvelope(
            envelopeText,
            expectedSegmentIDs: expectedSegmentIDs
        )
    }

    private static func encodedTranslationData(
        _ request: RemoteTranslationRequest
    ) throws -> String {
        let root: [String: Any] = [
            "source_language": request.sourceLanguage,
            "target_language": request.targetLanguage,
            "segments": request.segments.map {
                [
                    "id": $0.id,
                    "text": $0.text,
                ]
            },
            "context": request.context,
            "glossary": request.glossary.map {
                [
                    "source": $0.source,
                    "target": $0.target,
                ]
            },
        ]
        guard JSONSerialization.isValidJSONObject(root) else {
            throw RemoteTranslationError.invalidRequest(
                "translation data cannot be represented as JSON"
            )
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard let value = String(data: data, encoding: .utf8) else {
            throw RemoteTranslationError.invalidRequest(
                "translation data has an invalid UTF-8 encoding"
            )
        }
        return value
    }

    private static func responseSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "translations": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "id": [
                                "type": "string",
                            ],
                            "text": [
                                "type": "string",
                            ],
                        ],
                        "required": ["id", "text"],
                    ],
                ],
            ],
            "required": ["translations"],
        ]
    }

    private static func responsesEnvelopeText(_ root: [String: Any]) throws -> String {
        if let error = root["error"], !(error is NSNull) {
            throw RemoteTranslationError.invalidResponse(
                "the Responses API returned an error object"
            )
        }
        let hasIncompleteDetails = root["incomplete_details"] != nil &&
            !(root["incomplete_details"] is NSNull)
        if let status = root["status"] as? String {
            if status == "incomplete" || hasIncompleteDetails {
                throw RemoteTranslationError.invalidResponse(
                    "the Responses API response is incomplete"
                )
            }
            if status != "completed" {
                throw RemoteTranslationError.invalidResponse(
                    "the Responses API did not complete successfully"
                )
            }
        } else if hasIncompleteDetails {
            throw RemoteTranslationError.invalidResponse(
                "the Responses API response is incomplete"
            )
        }

        guard let output = root["output"] as? [Any] else {
            throw RemoteTranslationError.invalidResponse(
                "missing Responses API output array"
            )
        }
        var outputTexts: [String] = []
        for outputItem in output {
            guard let item = outputItem as? [String: Any] else { continue }
            if let itemStatus = item["status"] as? String,
               itemStatus != "completed"
            {
                throw RemoteTranslationError.invalidResponse(
                    "a Responses API output item did not complete"
                )
            }
            guard let content = item["content"] as? [Any] else { continue }
            for contentItem in content {
                guard let part = contentItem as? [String: Any] else { continue }
                if part["type"] as? String == "refusal" ||
                    (part["refusal"] as? String)?.isEmpty == false
                {
                    throw RemoteTranslationError.refused
                }
                if part["type"] as? String == "output_text",
                   let text = part["text"] as? String
                {
                    outputTexts.append(text)
                }
            }
        }
        guard outputTexts.count == 1, let text = outputTexts.first else {
            throw RemoteTranslationError.invalidResponse(
                "expected exactly one Responses API output_text item"
            )
        }
        return text
    }

    private static func chatCompletionsEnvelopeText(
        _ root: [String: Any]
    ) throws -> String {
        guard let choices = root["choices"] as? [Any] else {
            throw RemoteTranslationError.invalidResponse(
                "missing chat completions choices array"
            )
        }
        let indexedChoices = choices.compactMap { choice -> [String: Any]? in
            guard let choice = choice as? [String: Any],
                  (choice["index"] as? NSNumber)?.intValue == 0
            else {
                return nil
            }
            return choice
        }
        guard indexedChoices.count == 1,
              let choice = indexedChoices.first,
              let message = choice["message"] as? [String: Any]
        else {
            throw RemoteTranslationError.invalidResponse(
                "expected exactly one chat completion choice at index zero"
            )
        }
        if let finishReason = choice["finish_reason"] as? String {
            if finishReason == "content_filter" {
                throw RemoteTranslationError.refused
            }
            if finishReason == "length" {
                throw RemoteTranslationError.invalidResponse(
                    "the chat completion was truncated"
                )
            }
            if finishReason != "stop" {
                throw RemoteTranslationError.invalidResponse(
                    "the chat completion did not finish with text"
                )
            }
        }
        if (message["refusal"] as? String)?.isEmpty == false {
            throw RemoteTranslationError.refused
        }
        if let content = message["content"] as? String {
            return content
        }
        if let parts = message["content"] as? [Any] {
            let texts = parts.compactMap { value -> String? in
                guard let part = value as? [String: Any],
                      part["type"] as? String == "text"
                else {
                    return nil
                }
                return part["text"] as? String
            }
            guard texts.count == 1, let text = texts.first else {
                throw RemoteTranslationError.invalidResponse(
                    "expected exactly one text content part"
                )
            }
            return text
        }
        throw RemoteTranslationError.invalidResponse(
            "missing chat completion message content"
        )
    }

    private static func parseTranslationEnvelope(
        _ value: String,
        expectedSegmentIDs: [String]
    ) throws -> [RemoteTranslatedSegment] {
        let maximumEnvelopeBytes = expectedSegmentIDs.count
            .multipliedReportingOverflow(by: maximumTranslationBytes)
        guard !maximumEnvelopeBytes.overflow,
              value.utf8.count <= maximumEnvelopeBytes.partialValue + 16 * 1024,
              let data = value.data(using: .utf8)
        else {
            throw RemoteTranslationError.responseTooLarge
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RemoteTranslationError.invalidResponse(
                "structured translation is not valid JSON"
            )
        }
        guard let root = object as? [String: Any],
              Set(root.keys) == ["translations"],
              let translations = root["translations"] as? [Any],
              translations.count == expectedSegmentIDs.count
        else {
            throw RemoteTranslationError.invalidResponse(
                "structured translation does not match the required schema"
            )
        }

        let expectedIDs = Set(expectedSegmentIDs)
        var accepted: [String: String] = [:]
        for rawItem in translations {
            guard let item = rawItem as? [String: Any],
                  Set(item.keys) == ["id", "text"],
                  let id = item["id"] as? String,
                  expectedIDs.contains(id),
                  accepted[id] == nil,
                  let text = item["text"] as? String,
                  text.utf8.count <= maximumTranslationBytes,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw RemoteTranslationError.invalidResponse(
                    "structured translation contains an invalid segment"
                )
            }
            accepted[id] = text
        }
        guard accepted.count == expectedSegmentIDs.count else {
            throw RemoteTranslationError.invalidResponse(
                "structured translation is missing one or more segment IDs"
            )
        }
        return expectedSegmentIDs.compactMap { id in
            accepted[id].map { RemoteTranslatedSegment(id: id, text: $0) }
        }
    }
}
