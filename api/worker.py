"""One-request stdio entry point for Helm's bundled OCR helper."""
import base64
import io
import json
import os
from pathlib import Path
import sys

# PyInstaller relocates the runtime and all native libraries together. Never
# search the user's PATH or Homebrew installation in a distributed app.
if getattr(sys, "frozen", False):
    runtime = Path(sys._MEIPASS)
    os.environ["TESSERACT_CMD"] = str(runtime / "tesseract")
    os.environ["TESSDATA_PREFIX"] = str(runtime / "tessdata")

from fastapi import HTTPException, UploadFile
from pydantic import ValidationError
import pytesseract

from app import calculate_quote, extract
from pricing import QuoteInput


def handle(request):
    action, payload = request.get("action"), request.get("payload", {})
    if action == "extract":
        try:
            image = base64.b64decode(payload["image"], validate=True)
        except (ValueError, KeyError, TypeError):
            raise HTTPException(400, "Invalid image data.")
        file = UploadFile(file=io.BytesIO(image), headers={"content-type": payload.get("content_type", "image/png")})
        return extract(file)
    if action == "calculate":
        return calculate_quote(QuoteInput.model_validate(payload))
    raise HTTPException(400, "Unknown quotation action.")


def main():
    try:
        if sys.argv[1:] == ["--self-test"]:
            version = str(pytesseract.get_tesseract_version())
            languages = pytesseract.get_languages()
            if "eng" not in languages:
                raise RuntimeError("Bundled English OCR data is missing.")
            result = {"tesseract": version, "languages": languages}
        else:
            raw = sys.stdin.buffer.read(14 * 1024 * 1024 + 1)
            if len(raw) > 14 * 1024 * 1024:
                raise HTTPException(413, "Image must be 10 MB or smaller.")
            result = handle(json.loads(raw))
        response = {"ok": True, "result": result}
    except HTTPException as error:
        response = {"ok": False, "error": error.detail}
    except (ValidationError, ValueError, TypeError, AttributeError):
        response = {"ok": False, "error": "Check the image, filament weight, duration, and pricing rates."}
    except Exception as error:
        print(f"Helm OCR helper: {error}", file=sys.stderr)
        response = {"ok": False, "error": "The bundled OCR helper could not process this request. Try again."}
    print(json.dumps(response, allow_nan=False))


if __name__ == "__main__":
    main()
