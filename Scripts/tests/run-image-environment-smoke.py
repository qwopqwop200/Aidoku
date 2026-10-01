#!/usr/bin/env python3
"""Focused dotenv and actual CLI option-default parsing; no model or network calls."""
import json
from pathlib import Path
import subprocess
import tempfile
import os

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / 'Scripts/image-translation/PipelineMain.swift').read_text().split('@MainActor\n@main', 1)[0]
stubs = '''
enum IPhoneOCRModelTier: String { case tiny, small, medium }
enum RemoteTranslationProtocol: String { case responses, chatCompletions }
enum RemoteTranslationProvider { case custom }
enum OpenAIReasoningEffort: String { case modelDefault, none }
struct ReaderOCRConfiguration {
    let modelTier: IPhoneOCRModelTier; let detectorMaximumSide: Int; let recognizerMaximumWidth: Int
    let confidenceThreshold: Double; let detectorPixelThreshold: Double?; let detectorConfidenceThreshold: Double?
    let detectorMinimumBoxSide: Double
}
struct RemoteTranslationRequest {
    let sourceLanguage: String; let targetLanguage: String; let sourceText: String
    func validate() throws {}
}
struct RemoteTranslationConfiguration {
    let provider: RemoteTranslationProvider; let apiProtocol: RemoteTranslationProtocol
    let baseURL: String; let model: String; let credentialAccount: String
    let reasoningEffort: OpenAIReasoningEffort; let timeout: Double
    let allowsInsecureLocalhostForDevelopment: Bool
    func validatedEndpoint() throws -> URL { URL(string: baseURL)! }
}
enum HostError: Error { case message(String) }
// Geometry rendering itself has a separate regression. These dependencies are
// never invoked here; parseViewport is the actual host implementation.
enum ReaderTranslationBackgroundImage {
    static func pixelSize(for size: CGSize) -> CGSize { size }
}
enum HostProductionExportSizing {
    static func outputSize(for size: CGSize) -> CGSize { size }
}
enum ReaderTranslationGeometry {
    static func displayRect(_ rect: CGRect, imageSize: CGSize, bounds: CGRect, aspectFit: Bool) -> CGRect { bounds }
}
@main struct Check {
    static func main() {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            try HostEnvironment.load(root: root)
            let o = try HostOptions(root: root, arguments: Array(CommandLine.arguments.dropFirst(2)))
            let data = try JSONSerialization.data(withJSONObject: ["base":o.baseURL,"model":o.model,"protocol":o.apiProtocol.rawValue,
                "source":o.source,"target":o.target,"tier":o.tier.rawValue,"confidence":o.confidence,
                "detector":o.detectorSide,"recognizer":o.recognizerWidth,"image":o.includeImage,
                "sfx":o.filterSFX,"background":o.filterBackground,"rtl":o.rtl,
                "keyPresent":!(ProcessInfo.processInfo.environment[o.keyEnv] ?? "").isEmpty,
                "pixelThreshold":o.detectorPixelThreshold ?? -1,"boxThreshold":o.detectorConfidenceThreshold ?? -1,
                "minimumBoxSide":o.detectorMinimumBoxSide,"reasoning":o.reasoningEffort.rawValue,"timeout":o.timeout,
                "languages":o.translationSourceLanguages,"appearance":o.appearance,
                "jobs":o.jobs,"viewport":[o.viewport.width,o.viewport.height]])
            print(String(decoding:data,as:UTF8.self))
        } catch { fputs("\\(error)\\n",stderr);exit(2) }
    }
}
'''
with tempfile.TemporaryDirectory(prefix='aidoku-env-') as temporary:
    directory = Path(temporary)
    main = directory / 'Check.swift'; main.write_text(source + stubs)
    binary = directory / 'check'
    subprocess.run(['xcrun','swiftc','-parse-as-library',
        str(ROOT/'Scripts/image-translation/HostEnvironment.swift'),
        str(ROOT/'Scripts/image-translation/HostLetterFonts.swift'),
        str(ROOT/'Scripts/image-translation/HostRenderGeometry.swift'),
        str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/IPhoneOverlaySettings.swift'),
        str(main),'-o',str(binary)],check=True)
    profile = directory / 'profile'; profile.mkdir()
    secret = 'env-fixture-secret-$(touch should-not-exist)'
    settings = f'''# defaults\nexport AIDOKU_TRANSLATION_BASE_URL="https://example.test/v1" # url\nAIDOKU_TRANSLATION_MODEL='fixture model'\nAIDOKU_TRANSLATION_API_KEY='{secret}'\nAIDOKU_TRANSLATION_PROTOCOL=responses\nAIDOKU_TRANSLATION_SOURCE=ja\nAIDOKU_TRANSLATION_TARGET=en\nAIDOKU_OCR_TIER=tiny\nAIDOKU_OCR_CONFIDENCE=0.87\nAIDOKU_OCR_DETECTOR_SIDE=960\nAIDOKU_OCR_RECOGNIZER_WIDTH=800\nAIDOKU_TRANSLATION_INCLUDE_IMAGE=true\nAIDOKU_TRANSLATION_FILTER_SFX=1\nAIDOKU_TRANSLATION_FILTER_BACKGROUND=yes\nAIDOKU_TRANSLATION_RTL=on\n'''
    (profile/'.env').write_text(settings)
    with (profile/'.env').open('a') as fixture:
        fixture.write('AIDOKU_RENDER_VIEWPORT=390x844\nAIDOKU_IMAGE_JOBS=4\n')
    environment = {key:value for key,value in os.environ.items() if not key.startswith('AIDOKU_')}
    def run(args=(), extra=None, expected=0):
        result = subprocess.run([str(binary),str(profile),*args],env={**environment,**(extra or {})},cwd=directory,capture_output=True,text=True)
        assert result.returncode==expected,result.stdout+result.stderr
        assert secret not in result.stdout+result.stderr
        return json.loads(result.stdout) if expected==0 else result.stderr
    defaults=run()
    expected={'base':'https://example.test/v1','model':'fixture model','protocol':'responses','source':'ja','target':'en',
        'tier':'tiny','confidence':.87,'detector':960,'recognizer':800,'image':True,'sfx':True,'background':True,'rtl':True,'keyPresent':True}
    assert {key:defaults[key] for key in expected}==expected,defaults
    assert defaults['viewport']==[390,844] and defaults['jobs']==4
    shell=run(extra={'AIDOKU_TRANSLATION_MODEL':'shell','AIDOKU_TRANSLATION_TARGET':'ko','AIDOKU_RENDER_VIEWPORT':'414x896'})
    assert shell['model']=='shell' and shell['target']=='ko'
    assert shell['viewport']==[414,896]
    cli=run(['--model','cli','--tier','small','--confidence','.5','--source','auto','--target','ko','--protocol','chatCompletions',
             '--no-include-image','--no-filter-sfx','--no-filter-background','--no-rtl'],{'AIDOKU_TRANSLATION_MODEL':'shell'})
    assert cli['model']=='cli' and cli['tier']=='small' and cli['confidence']==.5 and cli['protocol']=='chatCompletions'
    assert not any(cli[k] for k in ['image','sfx','background','rtl'])
    cli_viewport=run(['--viewport','430x932','--jobs','2'],{'AIDOKU_RENDER_VIEWPORT':'414x896'})
    assert cli_viewport['viewport']==[430,932] and cli_viewport['jobs']==2
    for invalid in ['0x932','430x-1','nanx932','430xinf','16385x932','430x932x2']:
        assert 'Viewport' in run(['--viewport',invalid],expected=2)
    assert run(['--viewport','430×932'])['viewport']==[430,932]
    assert not (directory/'should-not-exist').exists()
    (profile/'.env').write_text("AIDOKU_TRANSLATION_API_KEY='unclosed-secret-value\n")
    error=run(expected=2);assert 'line 1' in error and 'unclosed-secret-value' not in error
    (profile/'.env').unlink()
    defaults=run(['--ocr-only']);assert defaults['tier']=='medium' and defaults['confidence']==.75 and not defaults['keyPresent']
    assert 'AIDOKU_TRANSLATION_INCLUDE_IMAGE' in run(['--ocr-only'],{'AIDOKU_TRANSLATION_INCLUDE_IMAGE':'invalid'},expected=2)
    # A saved phone profile is input data, not the developer's private .env.
    # Exercise all imported fields from a deterministic profile on every checkout.
    imported_settings = {
        'AIDOKU_TRANSLATION_PROTOCOL': 'responses',
        'AIDOKU_TRANSLATION_SOURCE': 'ja', 'AIDOKU_TRANSLATION_TARGET': 'ko',
        'AIDOKU_TRANSLATION_API_KEY': secret,
        'AIDOKU_OCR_CONFIDENCE': '0.81', 'AIDOKU_OCR_DETECTOR_SIDE': '1280',
        'AIDOKU_OCR_RECOGNIZER_WIDTH': '960',
        'AIDOKU_OCR_DETECTOR_PIXEL_THRESHOLD': '0.3',
        'AIDOKU_OCR_DETECTOR_CONFIDENCE_THRESHOLD': '0.3',
        'AIDOKU_OCR_DETECTOR_MINIMUM_BOX_SIDE': '3',
        'AIDOKU_TRANSLATION_INCLUDE_IMAGE': 'true',
        'AIDOKU_TRANSLATION_FILTER_SFX': 'true',
        'AIDOKU_TRANSLATION_FILTER_BACKGROUND': 'true',
        'AIDOKU_TRANSLATION_REASONING': 'none', 'AIDOKU_TRANSLATION_TIMEOUT': '120',
        'AIDOKU_TRANSLATION_SOURCE_LANGUAGES': json.dumps(['en', 'ja']),
        'AIDOKU_IPHONE_OVERLAY_JSON': json.dumps({
            'inpaintingEnabled': True, 'preserveSourceTextColor': True,
            'preserveSourceBackgroundColor': True}),
    }
    (profile / '.env').write_text(''.join(f"{key}='{value}'\n" for key, value in imported_settings.items()))
    actual = run(['--ocr-only'])
    assert actual['protocol'] == 'responses' and actual['source'] == 'ja' and actual['target'] == 'ko'
    assert actual['confidence'] == .81 and actual['detector'] == 1280 and actual['recognizer'] == 960
    assert actual['pixelThreshold'] == .3 and actual['boxThreshold'] == .3 and actual['minimumBoxSide'] == 3
    assert actual['image'] and actual['sfx'] and actual['background'] and actual['keyPresent']
    assert actual['reasoning'] == 'none' and actual['timeout'] == 120 and actual['languages'] == ['en', 'ja']
    assert actual['appearance']['inpaintingEnabled'] and actual['appearance']['preserveSourceTextColor']

assert subprocess.run(['git','check-ignore','-q','.env'],cwd=ROOT).returncode==0
assert subprocess.run(['git','check-ignore','-q','.env.example'],cwd=ROOT).returncode==1
assert subprocess.run(['git','ls-files','--error-unmatch','.env'],cwd=ROOT,capture_output=True).returncode!=0
print('PASS: dotenv parsing, cwd independence, .env/shell/CLI precedence, viewport validation, flags, no evaluation/secret output, Git exclusion')
