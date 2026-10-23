"""Local OCR and quotation service. Run from api/: uvicorn app:app --host 127.0.0.1."""
import io
import os
import threading
import time
from collections import Counter

import pytesseract
from fastapi import FastAPI, File, HTTPException, UploadFile
from PIL import Image, ImageOps, UnidentifiedImageError

from ocr import format_duration, parse_estimate, regions_and_variants
from pricing import QuoteInput, Rates, calculate

if os.getenv("TESSERACT_CMD"):
    pytesseract.pytesseract.tesseract_cmd = os.environ["TESSERACT_CMD"]

app = FastAPI(title="Helm Print Quote API", version="1.0.0")
ocr_slot = threading.BoundedSemaphore(1)
MAX_BYTES = 10 * 1024 * 1024


@app.get("/health")
def health():
    return {"status": "ok"}


def extract(file):
    if file.content_type not in {"image/png", "image/jpeg", "image/webp"}:
        raise HTTPException(415, "Upload a PNG, JPEG, or WebP image.")
    data = file.file.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise HTTPException(413, "Image must be 10 MB or smaller.")
    try:
        with Image.open(io.BytesIO(data)) as original:
            if original.format not in {"PNG", "JPEG", "WEBP"}:
                raise HTTPException(415, "Upload a PNG, JPEG, or WebP image.")
            if original.width * original.height > 25_000_000:
                raise HTTPException(413, "Image must be 25 megapixels or smaller.")
            original.verify()
        with Image.open(io.BytesIO(data)) as original:
            image = ImageOps.exif_transpose(original).convert("RGB")
        image.thumbnail((4000, 4000))
    except (Image.DecompressionBombError, Image.DecompressionBombWarning):
        raise HTTPException(413, "Image dimensions are too large.")
    except (UnidentifiedImageError, OSError, ValueError):
        raise HTTPException(400, "Invalid or corrupted image.")

    if not ocr_slot.acquire(blocking=False):
        raise HTTPException(429, "Another image is being scanned. Try again shortly.")
    try:
        readings = Counter()
        deadline = time.monotonic() + 60
        for variant, config in regions_and_variants(image):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            text = pytesseract.image_to_string(variant, config=config, timeout=min(8, remaining))
            grams, minutes = parse_estimate(text)
            if grams is not None and minutes is not None:
                pair = (round(grams, 3), minutes)
                readings[pair] += 1
                if readings[pair] >= 2:
                    return {"filament_grams": pair[0], "print_time_minutes": minutes,
                            "print_time": format_duration(minutes), "needs_review": True}
    except pytesseract.TesseractNotFoundError:
        raise HTTPException(503, "Tesseract is not installed. See api/README.md.")
    except (pytesseract.TesseractError, RuntimeError):
        raise HTTPException(503, "OCR failed or timed out. Crop around Total estimation and retry.")
    finally:
        ocr_slot.release()
    raise HTTPException(422, "Could not reliably read total filament and total time. Crop around Total estimation, retry, or enter the values manually.")


@app.post("/extract")
def extract_image(file: UploadFile = File(...)):
    return extract(file)


@app.post("/calculate")
def calculate_quote(request: QuoteInput):
    return {"currency": "INR", "quote": calculate(request.filament_grams, request.print_time_minutes, request.rates)}


@app.post("/quote")
def quote_image(file: UploadFile = File(...)):
    """Convenience endpoint for API clients using default rates; review OCR values."""
    result = extract(file)
    return {**result, "currency": "INR", "quote": calculate(result["filament_grams"], result["print_time_minutes"], Rates())}
