"""Small source-only acceptance gate: no native build or SDK import/download."""
import json
import pathlib

from gates import ROOT, load_lock

lock = load_lock()
for path in ROOT.rglob("*.py"):
    compile(path.read_text(), str(path), "exec")
workflow = (ROOT.parents[1] / ".github/workflows/max-runtime.yml").read_text()
for expected in ["timeout-minutes: 20", "persist-credentials: false", "contents: read", "--net", "--no-new-privs"]:
    if expected not in workflow:
        raise ValueError(f"Required hosted bound missing: {expected}")
for prohibited in ["actions/cache", "actions/upload-artifact", "pull_request_target", "secrets.", "--privileged"]:
    if prohibited in workflow:
        raise ValueError("Unexpected SDK workflow capability")
if workflow.count("runs-on:") != 1 or "if: github.event_name == 'workflow_dispatch'" not in workflow:
    raise ValueError("One manually activated CPU SDK job required")
print(json.dumps({"sourceGate": "passed", "lockSHA256": lock["lock_sha256"], "packages": len(lock["packages"]),
                  "downloadBytes": sum(p["size"] for p in lock["packages"]),
                  "binaryLicenseReviewRecorded": bool(lock["runtime_license_review"]), "sdkExecuted": False}))
