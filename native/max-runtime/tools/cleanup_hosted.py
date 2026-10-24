"""Remove only exact marked scratch created by this hosted MAX job."""
import os
import pathlib
import shutil
import sys

from gates import require_hosted

require_hosted()
root = pathlib.Path(sys.argv[1]).resolve(strict=True)
if root != pathlib.Path(os.environ["RUNNER_TEMP"]).resolve(strict=True):
    raise ValueError("Exact hosted runner temporary root required")
for name in ["max-sdk", "max-c-lifecycle"]:
    target = root / name
    if not target.exists():
        continue
    marker = target / ".quenderin-max-session-owned"
    if (target.is_symlink() or target.stat().st_uid != os.getuid() or marker.is_symlink()
            or not marker.is_file() or marker.read_bytes() != b"max-fixture-v1\n"):
        raise ValueError("Refusing to remove unowned MAX scratch")
    shutil.rmtree(target)
