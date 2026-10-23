import base64
import io
import json
import os
import subprocess
import sys
import unittest

from PIL import Image, ImageDraw, ImageFont



class WorkerTests(unittest.TestCase):
    def test_stdio_contract(self):
        request = {"action": "calculate", "payload": {"filament_grams": 100, "print_time_minutes": 120}}
        process = subprocess.run([sys.executable, "worker.py"], input=json.dumps(request), capture_output=True, text=True, timeout=15)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(process.stdout)["result"]["quote"]["final_price"], 529.75)

    def test_bad_request_returns_readable_error(self):
        process = subprocess.run([sys.executable, "worker.py"], input="broken JSON", capture_output=True, text=True, timeout=15)
        self.assertFalse(json.loads(process.stdout)["ok"])


@unittest.skipUnless(os.getenv("HELM_OCR_HELPER"), "Set HELM_OCR_HELPER to test the frozen runtime")
class BundledWorkerTests(unittest.TestCase):
    def run_helper(self, request=None, args=()):
        # Simulate a user's Mac without Python/Tesseract in PATH, and verify
        # inherited development settings cannot redirect the frozen OCR runtime.
        env = {**os.environ, "PATH": "/usr/bin:/bin", "TESSERACT_CMD": "/missing", "TESSDATA_PREFIX": "/missing"}
        process = subprocess.run([os.environ["HELM_OCR_HELPER"], *args],
                                 input=json.dumps(request) if request else "", capture_output=True, text=True,
                                 env=env, cwd="/private/tmp", timeout=90)
        self.assertEqual(process.returncode, 0, process.stderr)
        result = json.loads(process.stdout)
        self.assertTrue(result["ok"], result)
        return result["result"]

    def test_self_contained_runtime(self):
        self.assertIn("eng", self.run_helper(args=("--self-test",))["languages"])

    def test_real_ocr_and_pricing(self):
        image = Image.new("RGB", (900, 260), "white")
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 40)
        draw = ImageDraw.Draw(image)
        draw.text((25, 40), "Total filament: 100g", font=font, fill="black")
        draw.text((25, 130), "Total time: 2h", font=font, fill="black")
        output = io.BytesIO()
        image.save(output, format="PNG")
        reading = self.run_helper({"action": "extract", "payload": {
            "image": base64.b64encode(output.getvalue()).decode(), "content_type": "image/png"}})
        self.assertEqual(reading["filament_grams"], 100)
        self.assertEqual(reading["print_time_minutes"], 120)
        quote = self.run_helper({"action": "calculate", "payload": {
            "filament_grams": reading["filament_grams"], "print_time_minutes": reading["print_time_minutes"]}})
        self.assertEqual(quote["quote"]["final_price"], 529.75)


if __name__ == "__main__":
    unittest.main()
