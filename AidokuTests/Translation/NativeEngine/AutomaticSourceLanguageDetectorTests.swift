// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Testing
@testable import Aidoku

@Suite("Automatic translation source-language detection")
struct AutomaticSourceLanguageDetectorTests {
    @Test
    func sharedKanaBlockMarksDoNotOverrideChineseDocumentEvidence() {
        for text in ["你・現在有什麼打算？", "明天和朋友見面ーー？"] {
            #expect(AutomaticSourceLanguageDetector.detect(text, sourceHint: "zh-Hant") == "zh-Hant")
            #expect(AutomaticSourceLanguageDetector.allowsOCRText(text,
                configuredSourceLanguage: "zh-Hant", automaticLanguageFilter: []))
        }
    }

    @Test
    func actualKanaLettersKeepJapaneseEvidenceAcrossSharedMarks() {
        for text in ["ラーメン", "ﾗｰﾒﾝ", "カ・タ・カ・ナ", "あ゛", "ㇰ", "時々ある", "いすゞ", "サヽキ"] {
            #expect(AutomaticSourceLanguageDetector.detect(text) == "ja")
        }
        #expect(AutomaticSourceLanguageDetector.detect("夏生", sourceHint: "ja") == "ja")
    }

    @Test
    func sharedMarksAloneAreNotJapaneseEvidence() {
        for text in ["ー", "ｰ", "・", "･", "゛", "Hー"] {
            #expect(AutomaticSourceLanguageDetector.detect(text, sourceHint: "ja") == nil)
            #expect(!AutomaticSourceLanguageDetector.allowsOCRText(text,
                configuredSourceLanguage: "ja", automaticLanguageFilter: []))
        }
    }

    @Test
    func detectsEveryAppleBackedOCRSourceLanguageOnDevice() {
        let samples: [(String, String)] = [
            (
                "zh",
                "这是一个用于测试语言识别功能的简体中文句子，用户可以轻松阅读屏幕上的内容。"
            ),
            (
                "zh-Hant",
                "這是一個用於測試語言識別功能的繁體中文句子，使用者可以輕鬆閱讀螢幕上的內容。"
            ),
            (
                "en",
                "This detailed English sentence verifies reliable on-device language recognition in the browser."
            ),
            (
                "ja",
                "これはブラウザ上の言語認識機能を確認するための、十分に長い日本語の文章です。"
            ),
            (
                "cs",
                "Toto je podrobná česká věta určená k ověření spolehlivého rozpoznávání jazyka v prohlížeči."
            ),
            (
                "ca",
                "Aquesta és una frase catalana prou detallada per comprovar el reconeixement fiable de la llengua al navegador."
            ),
            (
                "hr",
                "Ovo je detaljna hrvatska rečenica za provjeru pouzdanog prepoznavanja jezika u pregledniku."
            ),
            (
                "da",
                "Dette er en detaljeret dansk sætning til at kontrollere pålidelig sproggenkendelse i browseren."
            ),
            (
                "de",
                "Dies ist ein ausführlicher deutscher Beispielsatz zur zuverlässigen Erkennung der Sprache im Browser."
            ),
            (
                "es",
                "Esta es una oración detallada en español para verificar el reconocimiento fiable del idioma en el navegador."
            ),
            (
                "fr",
                "Ceci est une phrase française détaillée destinée à vérifier la reconnaissance fiable de la langue dans le navigateur."
            ),
            (
                "fi",
                "Tämä on yksityiskohtainen suomenkielinen lause, jolla tarkistetaan luotettava kielen tunnistus selaimessa."
            ),
            (
                "hu",
                "Ez egy részletes magyar mondat a böngésző megbízható nyelvfelismerésének ellenőrzésére."
            ),
            (
                "id",
                "Pemerintah Indonesia mengumumkan bahwa warga harus membawa kartu identitas ketika datang ke kantor pemerintah."
            ),
            (
                "is",
                "Þetta er ítarleg íslensk setning til að staðfesta áreiðanlega tungumálagreiningu í vafranum."
            ),
            (
                "it",
                "Questa è una frase italiana dettagliata per verificare il riconoscimento affidabile della lingua nel browser."
            ),
            (
                "ms",
                "Kerajaan Malaysia mengumumkan bahawa rakyat perlu membawa kad pengenalan ketika berurusan di pejabat kerajaan."
            ),
            (
                "nl",
                "Dit is een uitgebreide Nederlandse zin om betrouwbare taalherkenning in de browser te controleren."
            ),
            (
                "no",
                "Jeg ønsker å undersøke hvorfor nettleseren ikke gjenkjenner denne tydelige norske teksten på en pålitelig måte."
            ),
            (
                "pl",
                "To jest szczegółowe polskie zdanie służące do sprawdzenia niezawodnego rozpoznawania języka w przeglądarce."
            ),
            (
                "pt",
                "Esta é uma frase detalhada em português para verificar o reconhecimento confiável do idioma no navegador."
            ),
            (
                "ro",
                "Aceasta este o propoziție românească detaliată pentru verificarea recunoașterii fiabile a limbii în browser."
            ),
            (
                "sk",
                "Toto je podrobná slovenská veta na overenie spoľahlivého rozpoznávania jazyka v prehliadači."
            ),
            (
                "sv",
                "Det här är en detaljerad svensk mening för att kontrollera tillförlitlig språkigenkänning i webbläsaren."
            ),
            (
                "tl",
                "Ang pamahalaan ng Pilipinas ay naglunsad ng bagong programa para sa mga mamamayan sa buong bansa."
            ),
            (
                "tr",
                "Bu, tarayıcıdaki güvenilir dil tanıma özelliğini doğrulamak için hazırlanmış ayrıntılı bir Türkçe cümledir."
            ),
            (
                "vi",
                "Đây là một câu tiếng Việt đủ dài để kiểm tra khả năng nhận dạng ngôn ngữ đáng tin cậy trong trình duyệt."
            ),
        ]

        #expect(
            Set(samples.map(\.0)) ==
                AutomaticSourceLanguageDetector
                    .automaticallyClassifiableLanguageCodes
        )
        #expect(
            AutomaticSourceLanguageDetector.supportedLanguageCodes.count == 50
        )
        #expect(
            AutomaticSourceLanguageDetector
                .automaticallyClassifiableLanguageCodes.isSubset(
                    of: AutomaticSourceLanguageDetector
                        .supportedLanguageCodes
                )
        )
        #expect(
            AutomaticSourceLanguageDetector
                .automaticallyClassifiableLanguageCodes.count == 27
        )
        #expect(
            AutomaticSourceLanguageDetector.supportedLanguageCodes
                .subtracting(
                    AutomaticSourceLanguageDetector
                        .automaticallyClassifiableLanguageCodes
                ).count == 23
        )
        for (expected, text) in samples {
            #expect(
                AutomaticSourceLanguageDetector.detect(text) == expected,
                "Expected \(expected) for: \(text)"
            )
        }
    }

    @Test
    func sourceFilterIsAppliedAfterFullLanguageClassification() {
        let german =
            "Diese deutsche Nachricht darf nicht als englischer Text gelten."

        #expect(AutomaticSourceLanguageDetector.allows(
            german,
            selectedLanguageCodes: []
        ))
        #expect(AutomaticSourceLanguageDetector.allows(
            german,
            selectedLanguageCodes: ["de"]
        ))
        #expect(!AutomaticSourceLanguageDetector.allows(
            german,
            selectedLanguageCodes: ["en"]
        ))
    }

    @Test
    func allLanguagesStillRejectsWhitespaceOnlyOCRArtifacts() {
        #expect(!AutomaticSourceLanguageDetector.allows(
            " \n\t",
            selectedLanguageCodes: []
        ))
        #expect(AutomaticSourceLanguageDetector.allows(
            "設定",
            selectedLanguageCodes: []
        ))
        #expect(AutomaticSourceLanguageDetector.allows(
            "価格 12,345円",
            selectedLanguageCodes: []
        ))
    }

    @Test
    func scriptEvidenceHandlesShortChineseAndJapaneseText() {
        #expect(AutomaticSourceLanguageDetector.detect("这") == "zh")
        #expect(AutomaticSourceLanguageDetector.detect("這") == "zh-Hant")
        #expect(AutomaticSourceLanguageDetector.detect("次へ") == "ja")
        #expect(AutomaticSourceLanguageDetector.detect("다음") == nil)
    }

    @Test
    func fixedJapaneseOCRSourceFiltersBeforeBrowserPublication() {
        #expect(AutomaticSourceLanguageDetector.allowsOCRText(
            "次へ",
            configuredSourceLanguage: "ja",
            automaticLanguageFilter: []
        ))
        #expect(AutomaticSourceLanguageDetector.allowsOCRText(
            "設定",
            configuredSourceLanguage: "ja",
            automaticLanguageFilter: []
        ))
        #expect(!AutomaticSourceLanguageDetector.allowsOCRText(
            "Open the advertising window now",
            configuredSourceLanguage: "ja",
            automaticLanguageFilter: []
        ))
        #expect(!AutomaticSourceLanguageDetector.allowsOCRText(
            "这是简体中文的广告页面",
            configuredSourceLanguage: "ja",
            automaticLanguageFilter: []
        ))
    }

    @Test
    func automaticOCRSourceUsesTheConfiguredLanguageAllowlist() {
        #expect(AutomaticSourceLanguageDetector.allowsOCRText(
            "これは日本語のメニューです",
            configuredSourceLanguage: "auto",
            automaticLanguageFilter: ["ja"]
        ))
        #expect(!AutomaticSourceLanguageDetector.allowsOCRText(
            "This English advertisement must be filtered out.",
            configuredSourceLanguage: "auto",
            automaticLanguageFilter: ["ja"]
        ))
        #expect(AutomaticSourceLanguageDetector.allowsOCRText(
            "This line remains when automatic filtering is disabled.",
            configuredSourceLanguage: "auto",
            automaticLanguageFilter: []
        ))
    }

    @Test
    func explicitSourceWithoutAppleClassifierRemainsUsable() {
        #expect(AutomaticSourceLanguageDetector.allowsOCRText(
            "Azərbaycan dilində mətn",
            configuredSourceLanguage: "az",
            automaticLanguageFilter: []
        ))
    }

    @Test
    func ambiguousInputUsesDeterministicConservativeFallbacks() {
        for text in [
            "",
            "12345 !?",
            "OK",
            "設定",
            "다음へ",
            "Saya membaca buku bersama keluarga.",
        ] {
            #expect(AutomaticSourceLanguageDetector.detect(text) == nil)
            #expect(AutomaticSourceLanguageDetector.detect(text) == nil)
            #expect(!AutomaticSourceLanguageDetector.allows(
                text,
                selectedLanguageCodes: ["en", "ja", "id"]
            ))
        }
    }
}
