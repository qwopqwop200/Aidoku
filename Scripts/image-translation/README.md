# Swift image translation pipeline runner

Run from the Aidoku repository root on Apple Silicon macOS 15+ with Xcode command-line tools:

```sh
# Image or folder only: use saved local server/OCR defaults and generate analysis.
swift Scripts/image-translation.swift /path/to/page.png
swift Scripts/image-translation.swift /path/to/images
```

`Aidoku/.env` (the Git root's `.env`) is read automatically, even when invoking
an absolute script path from another directory. The local file contains the supplied
server URL, model and credential plus OCR/translation defaults. Edit this file to
change the default profile. `.env` and `.env.*` are ignored by Git; `.env.example`
is a credential-free template. Priority is **CLI > shell environment > .env >
built-in defaults**. Boolean defaults can be disabled with `--no-include-image`,
`--no-filter-sfx`, `--no-filter-background` or `--no-rtl`.

The defaults were imported from the connected iPhone 15 Pro Max's installed
`dev.junjae.Aidoku` preferences: responses protocol, reasoning none, ja → ko,
source languages en/ja, page image and SFX/background filters enabled; medium OCR,
detector side 800, recognizer width 1200, recognition confidence 0.35, detector
pixel/box thresholds 0.3, minimum box side 3. Its overlay JSON is applied to the
host renderer's supported appearance fields. The supplied API key stays in `.env`;
the phone's Keychain is not accessed.

To refresh these defaults after changing phone settings:

```sh
python3 Scripts/image-translation/sync-iphone-settings.py \
  --device A6DD4676-9E0D-5EC2-BD63-2428CCF5D536
```

This copies the installed preference file and preserves the existing key. Scheduling
and cache preferences are saved separately as provenance: the CLI processes images with bounded workers (8 by default, `--jobs N` overrides),
overlaps remote translation, and uses production layout with AppKit font metrics, rather than
chapter preloading or UIKit layout. A saved `.env` profile works with the phone
disconnected. Dotenv supports `KEY=value`, quoted literals, comments and optional
`export`; values are never evaluated by a shell or expanded.
Secrets are neither printed nor copied into run artifacts.


```sh
# Folder; no provider required
swift Scripts/image-translation.swift --ocr-only --recursive /path/to/images

# Explicit image list
swift Scripts/image-translation.swift --ocr-only page1.png page2.jpg

# Newline-separated paths or a JSON array; relative paths resolve beside the list
swift Scripts/image-translation.swift --list /path/to/images.txt --ocr-only

# Real translation using the production remote client
# Repository .env supplies server/key/settings automatically.
# Shell environment and explicit CLI arguments override its defaults.
swift Scripts/image-translation.swift --list /path/to/images.json --source ja --target ko --include-image

# Local compatible server (loopback HTTP needs an explicit development flag)
swift Scripts/image-translation.swift --base-url http://127.0.0.1:8000/v1 \
  --model your-model --allow-local-http --target ko /path/to/page.png

# Replay translations without a provider: exact OCR source -> target text
# translations.json: {"ほら！早く動いて！": "어서! 빨리 움직여!"}
swift Scripts/image-translation.swift --translations translations.json /path/to/page.png

swift Scripts/image-translation.swift --help
```

Default output is `../output/image-translation/run-<UUID>/`. `--output DIR` changes
its parent; each invocation uses a fresh directory so input files and previous
results cannot be overwritten. Numbered image directories avoid same-basename
collisions. Input order is preserved; folder children are naturally sorted and
canonical duplicate paths are processed once. An unreadable or undecodable image
gets `error.json`; subsequent images continue. Configuration and missing-input
errors stop before loading models. Animated inputs use the first frame. EXIF
orientation is applied before OCR and export.

## Output

Every published stage is printed as JSON by default. `--quiet` keeps console
milestones while retaining all diagnostic files. The numbered JSON sequence
contains:

- Input dimensions and OCR configuration.
- Detector polygons, scores, selected counts, and all native diagnostics.
- Recognizer reads, confidence, model function/batch/load diagnostics, rejected
  reads, accepted lines and every returned recovery candidate.
- Initial grouping, recovery, balloon interiors, chromatic grouping, final OCR
  regions, phase times and optional RTL ordering.
- Language filtering, production translation batches and neighbor context.
- Actual HTTP bodies and response status/metrics, provisional streaming results
  and final parsed batches; authentication headers and key values are excluded.
- Rendering input, the production JavaScript result, final DOM geometry/styles/
  datasets, and render/snapshot dimensions and timing.

Each image also has `input.png`, `ocr-boxes.png`, `final.json` and, in translation
mode, `final.html` and `final.png`. Open `final.html` with its neighboring
`input.png` to replay the rendering. `summary.json` records every input, status,
region count, total elapsed milliseconds and errors. Failed images keep their
already-written intermediates.

## What runs

The launcher compiles a snapshot of the **current repository sources**, including
uncommitted changes, into a native Swift executable. It reuses incremental `-O`
object files and only rebuilds when source fingerprints change. Core ML packages
are compiled per tier once, with package-change invalidation. No app build,
simulator, Python OCR, Vision substitution, or third-party Swift package is used.

The Core ML detector/recognizer, recovery passes, ReaderOCRService grouping,
balloon evidence, language filtering, batch planner, HTTP codec, bounded
transport, protocol fallback and final browser JavaScript are production code.
The launcher injects diagnostic calls into generated copies under `build/`; it
never rewrites application sources. Test requests bypass the app's translation
result cache, so a previous app translation does not hide provider execution.
The host adapter uses NSSpellChecker in place of UIKit's UITextChecker.

The host now extracts the application's `layoutPayload`, card planner, collision/column/
balloon planning, rotation and text-flow code. It uses the bundled Myeongjo font
handler, the same overlay-settings normalization and the same 4MP WebKit background
budget. Final composition uses the production export script, repair masks, bounded
Core Image backdrop and PDF typography; export is capped at 12MP/16384 pixels.
Translation attachments use the app's 2048px, white-backed JPEG preparation and
unchanged-balloon recovery validation. Image-attached provider calls retain a maximum
of three simultaneous requests while page workers can overlap OCR/translation/rendering.

`--viewport WIDTHxHEIGHT` (or `AIDOKU_RENDER_VIEWPORT`) supplies the reader container
in screen points. The default 430x932 is the imported iPhone model's portrait screen
size, **not a live measurement of its reader view**; each page is aspect-fitted within
it. Use actual reader geometry for a device comparison. macOS Core Text/AppKit font
metrics, spelling dictionaries, color management and Core ML execution can still
differ from iOS. Host output does not establish exact device pixel parity.
Saved old render payloads retain their old layout when replayed with `--render-run`;
run the images again to generate the corrected production layout. OCR-only runs have
no translated PNG.

A neutral layout-only check avoids OCR and the provider:
`swift Scripts/image-translation.swift --layout-fixture fixture.json`.
Focused regressions include `run-image-layout-parity.py`,
`run-image-letter-fonts-smoke.py`, and `run-image-export-compositor-smoke.py`
under `Scripts/tests`. These verify production input policies and host output,
not live iPhone pixel equivalence.

Diagnostics capture stage-level results and recovery evidence, not every private
Core ML neural-network activation or local temporary variable. Credentials come
only from the selected environment variable; the tool does not read or modify
the app's saved provider settings or Keychain credentials.

Focused native smoke test (real Core ML OCR, offline replay, loopback mock provider,
folder/list selection, failure continuation, and credential exclusion):

```sh
python3 Scripts/tests/run-image-translation-smoke.py

# If another task is actively changing app sources, verify the last successful build:
python3 Scripts/tests/run-image-translation-smoke.py --reuse-built
```

The smoke test builds once, then runs all cases against that same executable.
`--reuse-built` explicitly uses the existing executable and does not validate
new app-source changes.

Exit codes: `0` all inputs succeeded, `1` preparation or per-image failures,
`2` invalid CLI/configuration/input selection. Provider failures are preserved as
failures rather than converted to fabricated translations.

### 분석 시각화

모든 실행은 `analysis-index.html`과 이미지별 `analysis.html`, `analysis.json`,
`analysis/*.png`를 자동 생성한다. 보고서는 인터넷 연결 없이 브라우저에서 열 수 있다.
단계 선택으로 검출 → 인식 → 거부·복구 → 병합 → 말풍선 → 번역 결과를 비교한다.
영역/표의 행을 클릭하면 원문, 신뢰도, 원본 좌표, 방향, 각도, 확대 크롭,
기울기 보정 미리보기와 원시 JSON을 확인할 수 있다. 레이어별로 검출 폴리곤,
읽기 축, 지움 후보, 말풍선 내부 스캔라인, 병합 구성 영역, 검출 확률을 켤 수 있다.

```sh
swift Scripts/image-translation.swift --visualize-run /absolute/path/to/run-UUID
```

이 명령은 기존 JSON과 `input.png`만 읽으며 OCR 모델이나 번역 서버를 사용하지 않는다.
실행 폴더 또는 개별 이미지 폴더를 받을 수 있다. 이전 실행에는 새 확률 맵·마스크
계측이 없을 수 있으므로 기록된 데이터만 표시한다.

좌표는 좌상단 원점의 원본 이미지 픽셀로 통일한다. 방향은 엔진의 orientation이며
추정 여부를 표시한다. 각도는 폴리곤 변에서 측정한 읽기 축과 그 기준 방향(H=0°, V=90°)
대비 기울기다. 시계 방향이 양수이며, 실제 글자 분류기의 회전값이 아니다.
방향이 없는 검출 상자는 `unknown`으로 남기고 장축만 제공한다. 보정 크롭은 분석용
기하학 미리보기이며 실제 인식 모델 입력 텐서가 아니다.

확률 맵은 실제 detector 출력 전체를 PNG 및 little-endian float32 `.f32`로 보존한다.
세그멘테이션 갤러리는 실제 production JS 함수 호출의 원본 크롭, 이진 마스크,
색상 오버레이를 저장한다. 폴리곤 소유 영역, 글자 마스크, 복원 후 픽셀 변화는
별도 종류로 표시하며, 함수가 반환한 후보가 최종 채택됐다는 뜻은 아니다.
OCR-only는 렌더러 마스크를 만들지 않는다. 마스크 캡처는 최대 64회/800만 픽셀로
제한하고 생략 횟수를 표시한다. 분석 PNG/메인 캔버스는 긴 변 1600px로 제한하지만
원본, 확률 raw 데이터와 세그멘테이션 크롭은 보존한다.

검증 명령:

```sh
python3 Scripts/tests/run-image-analysis-smoke.py
python3 Scripts/tests/run-image-translation-smoke.py
```

첫 번째는 모델 없이 저장 결과 변환, 좌표/각도, 안전한 HTML 삽입, 단계 선택/검색/크롭,
실제 세그멘테이션 함수의 계측 전후 일치 및 캡처 예산을 검사한다. 두 번째는 실제
Core ML OCR, 내장 이미지의 WebKit 픽셀 접근, 세그멘테이션 저장, 확률 맵 크기,
최종 렌더링과 로컬 모의 번역 서버를 검사한다. 이미 빌드된 동일 소스 스냅샷을
검증할 때만 두 번째 명령에 `--reuse-built`를 붙인다.

Dotenv/imported-phone option checks: `python3 Scripts/tests/run-image-environment-smoke.py`.

### 최종 합성 및 중단된 작업

최종 이미지는 이미지별 `final.png`와 실행 폴더의 `final/0001-원본이름.png`에 저장한다.
분석 HTML 상단에 최종 합성 결과를 표시하며, 실행 인덱스의 썸네일도 최종 결과를 사용한다.
큰 페이지에서 WebKit의 화면 밖 캡처가 원본 IMG 레이어를 생략할 수 있으므로,
번역 레이어를 흰색/검은색 매트로 캡처해 투명도를 복원하고 원본 CGImage 위에 합성한다.

```sh
# 저장된 번역/렌더링 인수로 최종 PNG 다시 합성 — OCR/서버 재호출 없음
swift Scripts/image-translation.swift --render-run /path/to/run-UUID

# 동일한 입력 순서/설정으로 이어서 처리 — 완료된 final.json은 재번역하지 않음
swift Scripts/image-translation.swift --resume-run /path/to/run-UUID /path/to/images
```

큰 이미지의 배경 픽셀 보존 및 번역 레이어 합성을 확인하는 집중 회귀 검증:
`python3 Scripts/tests/run-image-composite-smoke.py`.

### 병렬 실행

기본 `AIDOKU_IMAGE_JOBS=8`은 기기 동시 요청 설정에서 가져온 이미지 작업 수다.
`--jobs 1`로 순차 비교하거나 `--jobs 4` 등으로 조절할 수 있다(1~64).
이미지별 번역 요청을 동시에 보내고 그동안 다음 이미지 OCR을 진행한다.
공유 Core ML 파이프라인의 request generation 충돌을 막기 위해 실제 production
OCR gate를 사용한다. 큰 WebKit 창/래스터 메모리를 제한하기 위해 렌더링은
한 번에 한 이미지이며, 번역과 OCR은 그동안 계속 진행한다. 완료 순서가 달라도
이미지 번호, 덤프 문맥 및 summary 순서는 입력 기준으로 유지된다.

```sh
swift Scripts/image-translation.swift --jobs 8 /path/to/images
```

서버의 병렬 처리 능력과 렌더링 비중에 따라 속도 향상은 달라진다.
로컬 모의 서버로 동시 요청 중첩과 결과 순서를 검증하는 케이스는
`Scripts/tests/run-image-translation-smoke.py`에 포함되어 있다.

### OCR 소유권을 이용한 병합·색·삭제 검증

렌더러는 최종 `sourcePolygon`과 주변 OCR 폴리곤을 색 샘플 및 강제 삭제 마스크에
전달한다. 배경 RGB를 가공하지 않고 실제 연결 성분을 유지하면서 소유 영역의
잉크 후보를 검증한다. 기울어진 사각형의 빈 모서리와 이웃 글자는 삭제 후보에서
제외하며, 원본 채움색과 일치하는 독립적인 윤곽색 증거는 삭제에 사용할 수 있다.
폴리곤이 없거나 퇴화한 입력은 기존 경로를 사용한다. 가로 조각 병합도 항상
이미지 분리 검사(구분선·서로 다른 닫힌 종이 영역)를 존중한다.

빠른 회귀 검사:

```sh
node Scripts/tests/ocr-geometry-evidence-regression.cjs
python3 Scripts/tests/run-ocr-merger-evidence-smoke.py
```

저장된 실제 픽셀의 색 후보와 확률맵의 원래 8-연결 영역을 분석할 수 있다.
아래 선택적 분석 도구에는 Pillow가 필요하며 원본 이미지가 저장소에 추가되지 않는다.

```sh
python3 Scripts/tests/audit-output-hard-evidence.py --run RUN_DIRECTORY --output build/ocr-evidence
# 변경 전 소스 디렉터리를 보존했다면 --baseline BASELINE_OVERLAY_DIRECTORY 추가
```

`evidence-summary.json`의 색 변화/연결 영역 수는 진단 값이다. 정답 주석이 없는
이미지의 인식 정확도나 마스크 IoU를 뜻하지 않는다. 세그멘테이션 덤프에는 실제
팔레트와 크롭 좌표의 자기/이웃 폴리곤도 기록된다. `--render-run`은 새 단계 덤프를
추가하며, 캡처 PNG는 매 재생마다 별도 폴더에 저장해 이전 증거를 보존한다.

### Inpainting quality evidence

Forced restoration uses OCR polygon ownership, accepted ink/outline connected components and nearby caption donor exclusions. OCR-derived glyph size bounds component dimensions; a one-pixel finishing fringe replaces the former extra six-pixel expansion. Thick observed outlines and accepted detached dots receive an OCR-sized outline census. Component patch matching preserves locally supported texture; an edge-weighted relaxation inside the certified mask reduces donor streaks without changing surrounding pixels. Background donors are limited by actual spatial reach, so distant matching colors cannot overwrite nearby illustration edges. Unverified diffusion is rejected. Broad masks require an independently measured RGB plane with dense RMSE ≤ 3, no outliers and support on all four sides; reconstructed source core colors are checked before certification. An unrecoverable region retains a readability panel and discards an incomplete repair. This is a conservative fallback, not a guarantee that textured illustration can always be reconstructed.

Analysis records now include the original crop, binary paint mask, ownership overlay, actual repaired background and donor/surface quality. Rejected results remain distinguishable from adopted erasure. Focused regressions: `node Scripts/tests/forced-inpaint-quality-regression.cjs` , `node Scripts/tests/certified-inpaint-surface-regression.cjs`, and `node Scripts/tests/component-exemplar-inpaint-regression.cjs`. Captured arguments can be compared with `node Scripts/tests/output-hard-inpainting-replay.cjs CROPS_JSONL BASELINE_SWIFT_DIRECTORY REPORT_JSON`; real-page palette/paint counts are diagnostic evidence, not labelled accuracy scores.
