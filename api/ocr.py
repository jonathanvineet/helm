"""Creality Print OCR parsing and image variants, adapted from the supplied API."""
import re
from PIL import Image, ImageEnhance, ImageFilter, ImageOps

def label_type(line):
    """Identify labels even when OCR inserts icons or stray words before them."""
    line = line.lower()
    if re.search(r"\btota[l1]?\s*f(?:ilament|lament|iament|larnent)\b", line):
        return 'filament'
    if re.search(r"\bmodel\s*f(?:ilament|lament|iament)\b", line):
        return 'model_filament'
    if re.search(r"\btota[l1]?\s*t(?:ime|ine|me)\b", line):
        return 'time'
    return None


def parse_mass(line):
    """Extract the grams AFTER the filament label, never the preceding length in metres.

    Recognizes 5.85g, 5,85g and OCR 5,859 (= 5.85g, g->9).
    Ambiguous integer tokens with a 9 suffix are rejected. An integer with a
    genuine g suffix is preserved (e.g. 585g => 585 grams).
    """
    match = re.search(r"(?:total|model)\s*f(?:ilament|lament|iament|larnent)\s*:?", line, re.I)
    value_text = line[match.end():] if match else line
    # Require an explicit gram-like suffix, and avoid reading '1.96m' as grams.
    matches = list(re.finditer(r"(?<![\d.,])(\d{1,5}(?:[.,]\d{1,3})?)\s*([gG9])(?=\W|$)", value_text))
    if matches:
        m = matches[-1]
        token, suffix = m.group(1), m.group(2)
        if '.' in token or ',' in token:
            grams = float(token.replace(',', '.'))
        elif suffix == '9':
            # A missing decimal cannot be reconstructed reliably.
            return None
        else:
            grams = float(token)
        return grams if 0 < grams <= 10000 else None
    # Some OCR passes strip the unit entirely: accept only a decimal number
    # following a metre measurement, never a solitary ambiguous integer.
    meter = re.search(r"\d+(?:[.,]\d+)?\s*m\b", value_text, re.I)
    if meter:
        remainder = value_text[meter.end():]
        numeric = re.search(r"(?<!\d)(\d+[.,]\d{1,3})(?!\d)", remainder)
        if numeric:
            grams = float(numeric.group(1).replace(',', '.'))
            return grams if 0 < grams <= 10000 else None
    return None


def parse_time(line):
    """Parse explicit durations; never guess a missing decimal or hour separator."""
    match = re.search(r"tota[l1]?\s*t(?:ime|ine|me)\s*:?\s*", line, re.I)
    value = (line[match.end():] if match else line).lower()
    # Search all matches because an empty optional match may precede the duration.
    for match in re.finditer(
        r"(?<![\da-z])(?:(\d{1,3})\s*d\s*)?(?:(\d{1,3})\s*h\s*)?(?:(\d{1,5})\s*m)?(?![a-z])", value
    ):
        days, hours, minutes = match.groups()
        if not any((days, hours, minutes)):
            continue
        d, h, m = int(days or 0), int(hours or 0), int(minutes or 0)
        if (days is not None and h >= 24) or (hours is not None and m >= 60):
            return None
        total = d * 1440 + h * 60 + m
        return total if 0 < total <= 525600 else None
    return None


def format_duration(minutes):
    days, remainder = divmod(minutes, 1440)
    hours, mins = divmod(remainder, 60)
    if days:
        return f'{days}d{hours}h{mins:02d}m'
    return f'{hours}h{mins:02d}m'


def parse_estimate(text):
    grams = minutes = None
    for line in text.splitlines():
        kind = label_type(line)
        if kind == 'filament':
            value = parse_mass(line)
            if value is not None:
                grams = value
        elif kind == 'time':
            value = parse_time(line)
            if value is not None:
                minutes = value
    # Model-only filament can omit supports; do not silently underquote it.
    return grams, minutes


def regions_and_variants(img):
    w, h = img.size
    # The full image is essential when users upload a crop or a different layout.
    regions = [img]
    if w >= 500 and h >= 300:
        regions.extend([
            img.crop((int(w * .52), 0, w, h)),
            img.crop((int(w * .52), int(h * .18), w, h)),
            img.crop((0, int(h * .40), w, h)),
        ])
    for region in regions:
        if min(region.size) < 20:
            continue
        scale = min(3.0, 3600 / max(region.size))
        enlarged = region.resize((int(region.width * scale), int(region.height * scale)), Image.Resampling.LANCZOS)
        gray = ImageOps.grayscale(enlarged)
        contrast = ImageEnhance.Contrast(gray).enhance(2.3)
        sharpened = contrast.filter(ImageFilter.UnsharpMask(radius=1.5, percent=160, threshold=2))
        for variant in (gray, sharpened, ImageOps.autocontrast(gray)):
            for psm in (6, 11):
                yield variant, f'--oem 3 --psm {psm}'


