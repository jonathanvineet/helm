"""Freeze a relocatable, architecture-specific Python + Tesseract helper."""
import argparse
import ast
import fcntl
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def verify(bundle, arch):
    binary = bundle / "Contents/MacOS/helm-ocr"
    if not binary.is_file():
        raise SystemExit(f"Missing OCR helper: {binary}")
    # Reject accidental external dependencies, including development venvs.
    minimum_macos = (0,)
    for path in bundle.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        if command("/usr/bin/file", "-b", str(path)).startswith("Mach-O"):
            architectures = command("/usr/bin/lipo", "-archs", str(path)).split()
            if arch not in architectures:
                raise SystemExit(f"{path} does not contain {arch}")
            for line in command("/usr/bin/otool", "-L", str(path)).splitlines()[1:]:
                dependency = line.strip().split(" (", 1)[0]
                if dependency.startswith("/") and not dependency.startswith(("/usr/lib/", "/System/Library/")):
                    raise SystemExit(f"Nonportable dependency in {path}: {dependency}")
            for block in command("/usr/bin/otool", "-l", str(path)).split("Load command"):
                if "cmd LC_RPATH\n" in block:
                    rpath = re.search(r"\bpath (.+) \(offset", block)
                    if rpath and rpath[1].startswith("/") and not rpath[1].startswith(("/usr/lib/", "/System/Library/")):
                        raise SystemExit(f"Nonportable runtime search path in {path}: {rpath[1]}")
                key = "minos" if "cmd LC_BUILD_VERSION\n" in block else "version" if "cmd LC_VERSION_MIN_MACOSX\n" in block else None
                if key:
                    match = re.search(rf"^\s*{key}\s+([\d.]+)$", block, re.M)
                    if match:
                        minimum_macos = max(minimum_macos, tuple(int(part) for part in match[1].split(".")))
    if limit := os.environ.get("OCR_MAX_MACOS"):
        target = tuple(int(part) for part in limit.split("."))
        if minimum_macos > target + (0,) * (len(minimum_macos) - len(target)):
            required = ".".join(map(str, minimum_macos))
            raise SystemExit(f"OCR libraries require macOS {required}; release target is {limit}. Build Tesseract and its dependencies on/for the oldest supported macOS. See api/README.md.")
    if platform.machine() == arch:
        env = {**os.environ, "PATH": "/usr/bin:/bin", "TESSERACT_CMD": "/missing", "TESSDATA_PREFIX": "/missing"}
        result = json.loads(subprocess.check_output([str(binary), "--self-test"], env=env, text=True))
        if not result.get("ok"):
            raise SystemExit(f"Bundled OCR self-test failed: {result}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", required=True, choices=["arm64", "x86_64"])
    parser.add_argument("--verify", type=Path, help="Verify a prebuilt helper directory")
    args = parser.parse_args()
    (ROOT / "build").mkdir(exist_ok=True)
    build_lock = (ROOT / f"build/ocr-{args.arch}.lock").open("w")
    fcntl.flock(build_lock, fcntl.LOCK_EX)
    if args.verify:
        verify(args.verify, args.arch)
        return
    if args.arch != platform.machine():
        raise SystemExit(f"Build OCR on a {args.arch} Mac first, then set OCR_BUNDLE_DIR to a directory containing both architecture folders. See api/README.md.")
    try:
        importlib.metadata.version("pyinstaller")
    except importlib.metadata.PackageNotFoundError:
        raise SystemExit("Install api/requirements-build.txt into api/.venv before building Helm.")
    tesseract = Path(os.environ.get("TESSERACT_CMD") or shutil.which("tesseract") or "/opt/homebrew/bin/tesseract").resolve()
    if not tesseract.is_file():
        raise SystemExit("Build dependency missing: brew install tesseract (end users do not need Homebrew).")
    tessdata = Path(os.environ.get("TESSDATA_PREFIX", str(tesseract.parent.parent / "share/tessdata")))
    english = tessdata / "eng.traineddata"
    if not english.is_file():
        raise SystemExit(f"English OCR data missing: {english}")

    output = ROOT / "build/ocr" / args.arch
    bundle = output / "helm-ocr.app"
    sources = sorted((ROOT / "api").glob("*.py")) + [ROOT / "api/requirements-build.txt", ROOT / "api/requirements.txt", ROOT / "api/THIRD_PARTY.md"]
    digest = hashlib.sha256()
    for path in sources + [tesseract, english]:
        digest.update(path.read_bytes())
    digest.update(command(sys.executable, "-m", "pip", "freeze").encode())
    digest.update(sys.version.encode())
    stamp = output / "fingerprint"
    if stamp.is_file() and stamp.read_text() == digest.hexdigest() and (bundle / "Contents/MacOS/helm-ocr").is_file():
        print(f"Using cached {args.arch} OCR helper")
        verify(bundle, args.arch)
        return
    work = ROOT / "build/ocr-work" / args.arch
    work.mkdir(parents=True, exist_ok=True)
    spec = work / "helm-ocr.spec"
    # A real nested .app places data in Resources and code in Frameworks,
    # preserving console stdio while satisfying macOS signing layout rules.
    spec.write_text(f'''a = Analysis([{str(ROOT / "api/worker.py")!r}],
    pathex=[], binaries=[({str(tesseract)!r}, '.')],
    datas=[({str(english)!r}, 'tessdata')],
    excludes=['tkinter', 'pytest'])
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name='helm-ocr',
          console=True, target_arch={args.arch!r})
coll = COLLECT(exe, a.binaries, a.datas, name='helm-ocr')
app = BUNDLE(coll, name='helm-ocr.app',
             bundle_identifier='com.jonathanvineet.helm.ocr', version='1.0.0')
''')
    subprocess.run([
        sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean",
        "--distpath", str(output), "--workpath", str(work), str(spec),
    ], check=True, env={**os.environ, "PYINSTALLER_CONFIG_DIR": str(ROOT / "build/pyinstaller-cache")})
    # Retain Python package license notices in the distributed helper.
    licenses = bundle / "Contents/Resources/licenses"
    licenses.mkdir(exist_ok=True)
    for distribution in importlib.metadata.distributions():
        for file in distribution.files or []:
            if any(part.lower() in {"licenses", "license", "copying"} for part in file.parts) or file.name.lower().startswith(("license", "copying", "notice")):
                source = Path(distribution.locate_file(file))
                if source.is_file():
                    dest = licenses / distribution.metadata["Name"] / str(file)
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, dest)
    shutil.copy2(ROOT / "api/THIRD_PARTY.md", licenses / "THIRD_PARTY.md")
    for name in ("LICENSE", "AUTHORS"):
        source = tesseract.parent.parent / name
        if source.is_file():
            shutil.copy2(source, licenses / f"tesseract-{name}")
    # PyInstaller records source paths for every collected native dependency.
    # Preserve the Homebrew inventory and its bundled notices without relying on
    # the developer's Homebrew installation at runtime.
    analysis = ast.literal_eval((work / "helm-ocr/Analysis-00.toc").read_text())
    native_sources = set()
    for group in analysis:
        if isinstance(group, list):
            for item in group:
                if isinstance(item, tuple) and len(item) == 3 and item[2] in {"BINARY", "EXTENSION"}:
                    native_sources.add(item[1])
    (licenses / "native-dependencies.json").write_text(json.dumps(sorted(native_sources), indent=2))
    for name in native_sources:
        source = Path(name).resolve()
        if "/Cellar/" not in str(source):
            continue
        keg = next((parent for parent in source.parents if parent.parent.parent.name == "Cellar"), None)
        if keg is None:
            continue
        for notice in keg.iterdir():
            if notice.is_file() and notice.name.lower().startswith(("license", "copying", "notice", "authors", "readme", "sbom")):
                dest = licenses / "native" / keg.parent.name / notice.name
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(notice, dest)
    python_licenses = [Path(sys.base_prefix) / "LICENSE.txt",
                       Path(sys.base_prefix) / "Resources/English.lproj/Documentation/_sources/license.rst.txt"]
    for python_license in python_licenses:
        if python_license.is_file():
            shutil.copy2(python_license, licenses / "Python-LICENSE.txt")
            break
    else:
        raise SystemExit("Python license notice not found in this build interpreter. Include its license before redistributing.")
    subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(bundle)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    verify(bundle, args.arch)
    stamp.write_text(digest.hexdigest())


if __name__ == "__main__":
    main()
