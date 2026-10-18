#!/bin/bash
# Xcode Cloud runs this before dependency resolution.
set -euo pipefail
case "${CI_PRIMARY_REPOSITORY_PATH:-}" in
  /*) ;;
  *) echo "CI_PRIMARY_REPOSITORY_PATH must identify the absolute Quenderin checkout." >&2; exit 1 ;;
esac
if [ ! -d "$CI_PRIMARY_REPOSITORY_PATH" ]; then
  echo "CI_PRIMARY_REPOSITORY_PATH checkout is unavailable." >&2; exit 1
fi
ROOT="$(cd "$CI_PRIMARY_REPOSITORY_PATH" && pwd -P)"
for FILE in shared/prism-runtime.json shared/model-catalog.json scripts/verify_prism_apple_runtime.py apple/QuenderinKit/Package.swift apple/QuenderinApp/project.yml; do
  if [ ! -f "$ROOT/$FILE" ]; then
    echo "CI_PRIMARY_REPOSITORY_PATH is missing required Quenderin source: $FILE" >&2; exit 1
  fi
done
if [ "${CI:-}" != "TRUE" ] || [ "${QUENDERIN_RUNTIME:-}" != "prism" ] || [ -n "${QUENDERIN_LLAMA_DIR:-}" ]; then
  echo "Cloud archives require CI=TRUE and explicit QUENDERIN_RUNTIME=prism, without a local source override." >&2
  exit 1
fi
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
TOOLS="$ROOT/.quenderin-cloud-tools"
if [ -e "$TOOLS" ] || [ -L "$TOOLS" ]; then
  echo "Preserve existing Cloud tool path; use a fresh checkout." >&2; exit 1
fi
mkdir "$TOOLS"
# Official immutable release asset: one bounded request, no retries or upgrades.
curl --fail --location --connect-timeout 20 --max-time 120 --max-filesize 5000000 \
  https://github.com/yonaskolb/XcodeGen/releases/download/2.45.4/xcodegen.zip \
  --output "$TOOLS/xcodegen.zip"
python3 - "$TOOLS" <<'PY'
import hashlib, pathlib, shutil, stat, sys, zipfile
root = pathlib.Path(sys.argv[1])
asset = root / 'xcodegen.zip'
if asset.stat().st_size != 4319508 or hashlib.sha256(asset.read_bytes()).hexdigest() != '090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef':
    raise SystemExit('XcodeGen release asset checksum/size mismatch')
with zipfile.ZipFile(asset) as archive:
    entries = archive.infolist()
    seen = set()
    if sum(entry.file_size for entry in entries) > 20000000:
        raise SystemExit('Unexpected XcodeGen uncompressed size')
    for entry in entries:
        rel = pathlib.PurePosixPath(entry.filename)
        mode = entry.external_attr >> 16
        if (rel.is_absolute() or not rel.parts or rel.parts[0] != 'xcodegen'
                or '..' in rel.parts or '\\' in entry.filename
                or rel in seen or not (stat.S_ISREG(mode) or stat.S_ISDIR(mode))):
            raise SystemExit('Unsafe or unexpected XcodeGen release member')
        seen.add(rel)
        target = root.joinpath(*rel.parts)
        if target.exists() or target.is_symlink():
            raise SystemExit('Preserve existing XcodeGen bundle path')
    # Keep bin/ and share/ together: XcodeGen locates SettingPresets relative
    # to its executable. Extracting only the binary silently drops defaults.
    for entry in entries:
        target = root.joinpath(*pathlib.PurePosixPath(entry.filename).parts)
        if entry.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(entry) as source, target.open('xb') as destination:
                shutil.copyfileobj(source, destination)
            target.chmod((entry.external_attr >> 16) & 0o777)
    bundle = root / 'xcodegen'
    for name in ('base.yml', 'Configs/debug.yml', 'Configs/release.yml',
                 'Platforms/iOS.yml', 'Platforms/macOS.yml',
                 'Product_Platform/application_iOS.yml', 'Product_Platform/application_macOS.yml'):
        preset = bundle / 'share/xcodegen/SettingPresets' / name
        if not preset.is_file() or preset.stat().st_size == 0:
            raise SystemExit('XcodeGen bundle is missing required setting presets')
    if not (bundle / 'bin/xcodegen').is_file():
        raise SystemExit('XcodeGen bundle is missing its executable')
PY
export PATH="$TOOLS/xcodegen/bin:$PATH"
test "$(xcodegen --version)" = "Version: 2.45.4"
if ! command -v cmake >/dev/null; then
  command -v brew >/dev/null || { echo "Missing CMake and Homebrew." >&2; exit 1; }
  brew install cmake
fi
python3 - <<'PY'
import re, subprocess
version = tuple(map(int, re.search(r'version (\d+)\.(\d+)\.(\d+)', subprocess.check_output(['cmake', '--version'], text=True)).groups()))
if version < (3, 28, 0):
    raise SystemExit('Prism requires CMake >= 3.28.0')
PY
# Each Cloud checkout owns this new path. No existing source/build/framework path
# is replaced and the build script enforces available space before allocation.
"$ROOT/apple/build-prism-xcframework.sh" "$ROOT/.quenderin-cloud-prism-work"
"$ROOT/apple/build-diffusion-xcframework.sh" "$ROOT/.quenderin-cloud-diffusion-work"
python3 "$ROOT/scripts/verify_prism_apple_runtime.py" activate
xcodegen generate --spec "$ROOT/apple/QuenderinApp/project.yml"
git -C "$ROOT" diff --exit-code -- apple/QuenderinApp/Quenderin.xcodeproj/project.pbxproj apple/QuenderinApp/Quenderin.xcodeproj/xcshareddata/xcschemes
