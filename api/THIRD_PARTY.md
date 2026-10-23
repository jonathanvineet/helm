# Bundled OCR runtime

Helm's OCR helper contains Python, Python packages listed in requirements.txt,
Tesseract, Leptonica, English trained data, and their native library dependencies.
Python package license texts are copied into this directory during packaging.
Tesseract's LICENSE and AUTHORS are included when supplied by its distribution.

- Tesseract: https://github.com/tesseract-ocr/tesseract (Apache-2.0)
- English trained data: https://github.com/tesseract-ocr/tessdata_fast (Apache-2.0)
- Leptonica: https://github.com/DanBloomberg/leptonica (BSD-2-Clause)
- Python: https://docs.python.org/3/license.html (PSF-2.0 and included notices)
- PyInstaller bootloader: https://pyinstaller.org/en/stable/license.html
  (GPL with an exception permitting distribution of frozen applications)

The native dependency inventory and available Homebrew license notices are
included by the packager. Review these notices when changing the build toolchain
or redistributing a release.
