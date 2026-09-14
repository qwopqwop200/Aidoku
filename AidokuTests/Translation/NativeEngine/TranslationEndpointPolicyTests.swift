// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation
import Testing
@testable import Aidoku

struct TranslationEndpointPolicyTests {
    @Test func privateEndpointConnectivityErrorUsesProviderNeutralGuidance() {
        let message = RemoteTranslationError.privateTailnetUnavailable.localizedDescription

        #expect(
            message
                == "The translation API could not be reached. Check your network connection, API endpoint, and server status, then try again."
        )
        #expect(!message.localizedCaseInsensitiveContains("tailscale"))
        #expect(!message.localizedCaseInsensitiveContains("vpn"))
    }

    @Test func openAIUsesTheFixedResponsesEndpoint() throws {
        let configuration = RemoteTranslationConfiguration.openAI(model: "gpt-5-mini")
        let endpoint = try configuration.validatedEndpoint()
        #expect(endpoint.absoluteString == "https://api.openai.com/v1/responses")
    }

    @Test func customBasePathsDoNotDuplicateProtocolSuffixes() throws {
        let cases: [(String, RemoteTranslationProtocol, String)] = [
            (
                "https://example.test",
                .responses,
                "https://example.test/v1/responses"
            ),
            (
                "https://example.test/v1",
                .responses,
                "https://example.test/v1/responses"
            ),
            (
                "https://example.test/openai/v1",
                .chatCompletions,
                "https://example.test/openai/v1/chat/completions"
            ),
            (
                "https://example.test/v1/chat/completions",
                .chatCompletions,
                "https://example.test/v1/chat/completions"
            ),
        ]
        for (baseURL, apiProtocol, expected) in cases {
            let endpoint = try customConfiguration(
                baseURL: baseURL,
                apiProtocol: apiProtocol
            ).validatedEndpoint()
            #expect(endpoint.absoluteString == expected)
        }
    }

    @Test func plaintextRequiresAnExplicitCanonicalLoopbackOptIn() throws {
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            let endpoint = try customConfiguration(
                baseURL: "http://\(host):8080/v1",
                allowsDevelopmentHTTP: true
            ).validatedEndpoint()
            #expect(endpoint.scheme == "http")
        }

        for rejected in [
            customConfiguration(
                baseURL: "http://localhost:8080/v1",
                allowsDevelopmentHTTP: false
            ),
            customConfiguration(
                baseURL: "http://example.test/v1",
                allowsDevelopmentHTTP: true
            ),
            customConfiguration(
                baseURL: "http://127.1:8080/v1",
                allowsDevelopmentHTTP: true
            ),
            customConfiguration(
                baseURL: "http://%6cocalhost:8080/v1",
                allowsDevelopmentHTTP: true
            ),
        ] {
            do {
                _ = try rejected.validatedEndpoint()
                #expect(Bool(false), "unsafe plaintext endpoint was accepted")
            } catch RemoteTranslationError.insecureEndpoint {
                // Expected.
            }
        }
    }

    @Test func credentialsQueriesFragmentsAndProtocolMismatchesAreRejected() {
        for baseURL in [
            "https://user:secret@example.test/v1",
            "https://example.test/v1?token=secret",
            "https://example.test/v1#fragment",
            "https://example.test/v1/chat/completions",
        ] {
            do {
                _ = try customConfiguration(baseURL: baseURL).validatedEndpoint()
                #expect(Bool(false), "unsafe provider URL was accepted")
            } catch {
                #expect(error is RemoteTranslationError)
            }
        }
    }

    @Test func localNetworkEndpointsAreIdentifiedWithoutDNS() {
        for baseURL in [
            "https://192.168.1.2:8443/v1",
            "https://10.0.0.4/v1",
            "https://172.20.1.5/v1",
            "https://169.254.3.4/v1",
            "https://translator.local/v1",
            "https://translator.home.arpa/v1",
            "https://translator/v1",
            "https://[fd00::1]/v1",
            "https://[fe80::1]/v1",
        ] {
            #expect(
                TranslationEndpointPolicy.requiresLocalNetworkPermission(
                    for: customConfiguration(baseURL: baseURL)
                )
            )
        }
        for baseURL in [
            "https://api.openai.com/v1",
            "https://example.test/v1",
            "https://8.8.8.8/v1",
            "https://[2606:4700:4700::1111]/v1",
        ] {
            #expect(
                !TranslationEndpointPolicy.requiresLocalNetworkPermission(
                    for: customConfiguration(baseURL: baseURL)
                )
            )
        }
        #expect(
            !TranslationEndpointPolicy.requiresLocalNetworkPermission(
                for: .openAI(model: "gpt-5-mini")
            )
        )
    }

    @Test func transportWaitsForConnectivityWithinItsTimeouts() {
        for bypassesProxy in [false, true] {
            let configuration =
                BoundedURLSessionTransport.sessionConfiguration(
                    bypassesProxy: bypassesProxy
                )
            #expect(!configuration.waitsForConnectivity)
            #expect(configuration.timeoutIntervalForRequest == 300)
            #expect(configuration.timeoutIntervalForResource == 300)
            #expect(configuration.httpMaximumConnectionsPerHost == 64)
        }
    }

    private func customConfiguration(
        baseURL: String,
        apiProtocol: RemoteTranslationProtocol = .responses,
        allowsDevelopmentHTTP: Bool = false
    ) -> RemoteTranslationConfiguration {
        RemoteTranslationConfiguration(
            provider: .custom,
            apiProtocol: apiProtocol,
            baseURL: baseURL,
            model: "custom-model",
            credentialAccount: "custom",
            allowsInsecureLocalhostForDevelopment: allowsDevelopmentHTTP
        )
    }
}
