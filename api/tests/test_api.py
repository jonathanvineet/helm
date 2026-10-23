import io
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
from PIL import Image
from pytesseract import TesseractNotFoundError

from app import app, ocr_slot
from ocr import parse_estimate, parse_mass, parse_time
from pricing import Rates, calculate


class ParsingTests(unittest.TestCase):
    def test_total_fields_and_units(self):
        self.assertEqual(parse_estimate("Model filament: 2g\nTotal filament: 1.96m 5.85g\nModel printing time: 2m\nTotal time: 1d15h5m"), (5.85, 2345))
        self.assertEqual(parse_mass("Total filament: 1,96m 5,85g"), 5.85)
        self.assertEqual(parse_mass("Total filament: 585g"), 585)
        self.assertIsNone(parse_mass("Total filament: 5859"))
        self.assertIsNone(parse_mass("Total filament: 1.96m"))

    def test_durations_are_not_guessed(self):
        for text, minutes in [("45m", 45), ("458m", 458), ("4h58m", 298), ("2h", 120), ("3d", 4320)]:
            self.assertEqual(parse_time("Total time: " + text), minutes)
        for text in ["0m", "1d25h", "1h90m", "unknown"]:
            self.assertIsNone(parse_time("Total time: " + text))

    def test_model_filament_is_not_total(self):
        self.assertEqual(parse_estimate("Model filament: 5g\nTotal time: 45m"), (None, 45))

    def test_pricing_and_markup(self):
        result = calculate(100, 120, Rates())
        self.assertEqual(result["subtotal"], 286)
        self.assertEqual(result["buffers"], 71.5)
        self.assertEqual(result["manufacturing"], 407.5)
        self.assertEqual(result["profit"], 122.25)
        self.assertEqual(result["final_price"], 529.75)


class APITests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)
        output = io.BytesIO()
        Image.new("RGB", (200, 150), "white").save(output, format="PNG")
        self.image = output.getvalue()

    def upload(self, path="/extract", data=None, mime="image/png"):
        return self.client.post(path, files={"file": ("estimate.png", self.image if data is None else data, mime)})

    def test_health_and_calculate(self):
        self.assertEqual(self.client.get("/health").json(), {"status": "ok"})
        response = self.client.post("/calculate", json={"filament_grams": 100, "print_time_minutes": 120})
        self.assertEqual(response.json()["quote"]["final_price"], 529.75)
        custom = self.client.post("/calculate", json={"filament_grams": 100, "print_time_minutes": 120, "rates": {"profit_percent": 0}})
        self.assertEqual(custom.json()["quote"]["final_price"], 407.5)

    def test_reject_invalid_inputs(self):
        for payload in [
            {"filament_grams": -1, "print_time_minutes": 120},
            {"filament_grams": 1, "print_time_minutes": 0},
            {"filament_grams": 1, "print_time_minutes": 10, "rates": {"packaging": -1}},
            {"filament_grams": "NaN", "print_time_minutes": 10},
        ]:
            self.assertEqual(self.client.post("/calculate", json=payload).status_code, 422)
        self.assertEqual(self.upload(data=b"not an image").status_code, 400)
        self.assertEqual(self.upload(mime="text/plain").status_code, 415)
        self.assertEqual(self.upload(data=b"x" * (10 * 1024 * 1024 + 1)).status_code, 413)

    @patch("app.pytesseract.image_to_string")
    def test_extract_and_quote(self, ocr):
        ocr.return_value = "Total filament: 100g\nTotal time: 2h"
        response = self.upload()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["filament_grams"], 100)
        self.assertTrue(response.json()["needs_review"])
        self.assertEqual(ocr.call_count, 2)
        self.assertEqual(self.upload("/quote").json()["quote"]["final_price"], 529.75)

    @patch("app.pytesseract.image_to_string")
    def test_incomplete_or_conflicting_readings(self, ocr):
        ocr.return_value = "Total filament: 5g"
        self.assertEqual(self.upload().status_code, 422)
        ocr.side_effect = [f"Total filament: {n}g\nTotal time: 45m" for n in range(1, 7)]
        self.assertEqual(self.upload().status_code, 422)

    @patch("app.pytesseract.image_to_string", side_effect=RuntimeError("timeout"))
    def test_timeout_releases_slot(self, ocr):
        self.assertEqual(self.upload().status_code, 503)
        self.assertTrue(ocr_slot.acquire(blocking=False))
        ocr_slot.release()

    @patch("app.pytesseract.image_to_string", side_effect=TesseractNotFoundError())
    def test_missing_tesseract(self, ocr):
        response = self.upload()
        self.assertEqual(response.status_code, 503)
        self.assertIn("Tesseract is not installed", response.json()["detail"])

    def test_busy(self):
        ocr_slot.acquire()
        try:
            self.assertEqual(self.upload().status_code, 429)
        finally:
            ocr_slot.release()


if __name__ == "__main__":
    unittest.main()
