# Bundled OCR and print quotation API

This service reads **Creality Print estimate screenshots**, not the geometry of
an object in a photograph. Helm runs a bundled Python/Tesseract helper, asks you to
review the extracted grams and minutes, then calculates a quote using your saved
rates. Images stay on the Mac. Private temporary files are removed after each
request. Nothing needs to run in a terminal for the installed app.

## Build the self-contained app

Build dependencies only: Python 3.10+, Tesseract with English trained data,
PyInstaller, and Xcode command-line tools. Installed app users need none of these.
From the repository root:

```sh
brew install tesseract
python3 -m venv api/.venv
api/.venv/bin/python -m pip install -r api/requirements-build.txt
./build.sh
open build/Helm.app
```

Choose **Print Quote…** from Helm's menu bar. Choose or paste a screenshot, or
choose **Capture Screen…** to hide Helm and select the estimate area. Press Space
in the macOS picker to choose a window; Escape cancels. Helm restores the quote
window afterward. Screen capture requires macOS Screen & System Audio Recording
permission; choosing/pasting an image does not. Paste reads the existing clipboard
image; it cannot remove Helm from a screenshot that already contains Helm.

Scan, review the readings, adjust Pricing rates, and calculate. You can enter grams
and minutes manually if OCR fails. History and screensaver quotation cards are not
implemented.

The build freezes Python, Tesseract, native dependencies, and `eng.traineddata`
under `Contents/Helpers/OCR/<architecture>/helm-ocr.app/`. Helm launches this helper
once per operation using a private JSON stdin/stdout contract, with a 90-second
watchdog. Helpers exit after replying and are stopped if Helm quits. No HTTP
listener, server URL, global Python installation, or Homebrew installation is
used at runtime. The development HTTP API remains available separately.

`TESSERACT_CMD` and `TESSDATA_PREFIX` can select build inputs; the frozen worker
always uses its own packaged binary and data. `OCR_BUILD_PYTHON` selects the build
interpreter. Cached helpers are invalidated when sources or dependencies change.

### Universal releases and macOS compatibility

A thin Homebrew library cannot be converted into a universal library with lipo.
Build an OCR helper on each supported architecture:

```sh
api/.venv/bin/python api/build_bundle.py --arch arm64
# On an Intel build machine:
api/.venv/bin/python api/build_bundle.py --arch x86_64
```

Combine their output into one directory containing `arm64/helm-ocr.app/` and
`x86_64/helm-ocr.app/`. Then point `OCR_BUNDLE_DIR` at that directory when building or
running `release.sh`. Packaging verifies all Mach-O architectures and rejects
dependencies that still reference the build machine's Python/Homebrew paths.

Native libraries must also support the oldest target macOS version. Recent
Homebrew bottles may target a newer macOS than Helm's macOS 14 minimum. Use a
macOS 14 build environment or explicitly build native dependencies for macOS 14
before shipping. CI does this with `api/build_tesseract.sh <prefix>`, which builds a
static, PNG-only Tesseract for macOS 14.0; pass `TESSERACT_CMD=<prefix>/bin/tesseract`
and `TESSDATA_PREFIX=<prefix>/share/tessdata` to `build_bundle.py`. `release.sh` enforces `OCR_MAX_MACOS=14.0` and fails early if a
bundled library needs a newer OS. Local development builds use your installed
libraries without that release constraint. Test on the oldest supported OS before
publishing; do not lower a library's deployment metadata to bypass this check.

## Optional development HTTP API

For API development or clients outside Helm:

```sh
cd api
.venv/bin/uvicorn app:app --host 127.0.0.1 --port 8000
```

Keep that terminal running only while testing the HTTP API. The installed Helm
app does not use this listener. Set `TESSERACT_CMD` if Tesseract is outside PATH.

## Endpoints

Interactive API documentation: <http://127.0.0.1:8000/docs>.

| Endpoint | Input | Output |
| --- | --- | --- |
| `GET /health` | None | Service status (does not check Tesseract) |
| `POST /extract` | Multipart image in `file` | `filament_grams`, `print_time_minutes`, `print_time`, `needs_review` |
| `POST /calculate` | JSON with `filament_grams`, `print_time_minutes`, optional `rates` | `currency` and `quote` cost breakdown |
| `POST /quote` | Multipart image in `file` | Extracted values and quote at default rates |

Example requests:

```sh
curl -F 'file=@estimate.png' http://127.0.0.1:8000/extract
curl -H 'Content-Type: application/json' \
  -d '{"filament_grams":100,"print_time_minutes":120,"rates":{"profit_percent":30}}' \
  http://127.0.0.1:8000/calculate
```

Rates: `filament_per_gram`, `machine_per_hour`, `electricity_per_hour`,
`maintenance_percent`, `risk_percent`, `labour_percent`, `design_percent`,
`packaging`, `profit_percent`. Omitted rates use the supplied API's defaults:
₹2.5/g, ₹10 machine/hour, ₹8 electricity/hour, 5/5/10/5% buffers, ₹50 packaging,
30% profit markup. These are sample business rates, not market prices.

Buffers apply to filament + machine + electricity. Packaging is added once,
then profit markup applies to that manufacturing cost. This is markup, not margin.
The quote is INR and excludes tax and shipping. Monetary arithmetic uses Decimal
and half-up rounding to two places at output.

## OCR limits and failures

PNG, JPEG and WebP only, at most 10 MB and 25 megapixels. Include **Total filament**
and **Total time**. Model filament is not accepted as a substitute because it may
exclude support material. Two preprocessing variants must agree on both values.
Repeated OCR is still not proof of correctness; always review the displayed
values. Durations such as `45m`, `4h58m`, and `1d15h5m` are supported; `458m` means
458 minutes, with no guessed missing `h`.

OCR runs one image at a time, with per-pass timeouts and a 60-second processing
budget. A busy service returns 429; unreadable fields return 422; missing
Tesseract or OCR failure returns 503. Enter values manually or crop and retry.

The optional HTTP service is intended for loopback use. It has no authentication and should not
be exposed publicly as-is. Remote deployment needs authentication, request limits,
and HTTPS, along with a matching authenticated client implementation.

## Tests

```sh
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python -m unittest discover -s tests -v
```

Tests cover parsing, pricing, validation, the worker contract, and HTTP contracts.
To include real OCR tests against a built helper, run from `api/`:

```sh
HELM_OCR_HELPER="$PWD/../build/ocr/arm64/helm-ocr.app/Contents/MacOS/helm-ocr" \
  .venv/bin/python -m unittest discover -s tests -v
```

Use `x86_64` instead of `arm64` on Intel. These tests remove Homebrew from PATH and
set invalid external Tesseract paths to confirm the frozen helper uses its own
runtime. They read a synthetic estimate image and calculate the expected quote.
Interactive capture permission, selection, cancellation, and window restoration
should also be checked manually in the built app.
