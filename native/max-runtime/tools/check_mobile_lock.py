"""Fail-closed gate for the mobile MAX/Bonsai source receipt.

This validates recorded facts and their consistency with the shared catalog.
It performs no network access and never treats a social post as evidence of a
working mobile backend.
"""
from __future__ import annotations

import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
CATALOG = ROOT.parents[1] / "shared" / "model-catalog.json"
STATUS = "blocked-no-public-mobile-backend"
PATTERNS = {"adreno", "android", "qualcomm", "hexagon", "qnn", "dragonfly"}
REQUIRED = {
    "public-mobile-backend",
    "reviewed-mef-contract",
    "exact-binary-terms",
    "telemetry-proof",
    "android-jni-packaging",
    "apple-ios-artifact",
    "phone-validation",
}


def load_lock(path: pathlib.Path = ROOT / "mobile-lock.json") -> dict:
    raw = path.read_bytes()
    if len(raw) > 65536:
        raise ValueError("Mobile lock exceeds 64 KiB")
    return json.loads(raw)


def catalog_entry(model_id: str) -> dict:
    catalog = json.loads(CATALOG.read_text())
    for entry in catalog.get("models", []):
        if entry.get("id") == model_id:
            return entry
    raise ValueError("Pinned mobile model is absent from the shared catalog")


def _text(value: object, maximum: int) -> str:
    if not isinstance(value, str) or not value.strip() or len(value.encode()) > maximum:
        raise ValueError("Bounded non-empty text required")
    return value


def validate(lock: dict, entry: dict) -> None:
    if lock.get("schema") != 1 or lock.get("status") != STATUS:
        raise ValueError("Only the audited blocked status is accepted")
    if not re.fullmatch(r"2026-[0-9]{2}-[0-9]{2}", _text(lock.get("updated"), 10)):
        raise ValueError("Dated lock required")

    movement = lock.get("movement", {})
    if (movement.get("sourceRevision") != "527d069ee11a41ac5320af1f9402db0a66b2b868"
            or movement.get("sourceVersion") != "26.7.0"
            or not re.fullmatch(r"2026-[0-9]{2}-[0-9]{2}", _text(movement.get("auditDate"), 10))
            or movement.get("treePaths") != 13588
            or movement.get("mobileBackendPaths") != 0
            or set(movement.get("mobilePatterns", [])) != PATTERNS
            or movement.get("publishedBinaryTerms") != "LicenseRef-MAX-Platform-Software-License"
            or movement.get("redistribution") != "not-cleared-for-mobile"):
        raise ValueError("Unreviewed MAX source identity or mobile claim")
    blog = movement.get("blog", {})
    if (blog.get("url") != "https://www.modular.com/blog/26-7"
            or "Qualcomm Dragonfly" not in _text(blog.get("statement"), 1024)
            or "coming months" not in blog["statement"]):
        raise ValueError("Official deferred-plugin statement required")
    license_record = movement.get("sourceLicense", {})
    if (license_record.get("path") != "Licenses/LICENSE"
            or license_record.get("title") != "Modular MAX Community License"
            or license_record.get("lastModified") != "2026-08-18"
            or license_record.get("bytes") != 13342
            or not re.fullmatch(r"[a-f0-9]{64}", _text(license_record.get("sha256"), 64))):
        raise ValueError("Pinned source license receipt required")

    refresh = lock.get("refresh", {})
    if (not re.fullmatch(r"2026-[0-9]{2}-[0-9]{2}", _text(refresh.get("checkedAt"), 10))
            or not re.fullmatch(r"[a-f0-9]{40}", _text(refresh.get("mainRevision"), 40))
            or refresh["mainRevision"] == movement.get("sourceRevision")
            or not re.fullmatch(r"2026-[0-9]{2}-[0-9]{2}", _text(refresh.get("mainCommitDate"), 10))
            or refresh.get("mainTreePaths") != 16637
            or refresh.get("mainMobileBackendPaths") != 0
            or refresh.get("officialRelease") != "max/v26.7.0"
            or not re.fullmatch(r"2026-[0-9]{2}-[0-9]{2}", _text(refresh.get("officialReleaseDate"), 10))
            or refresh.get("pypiVersion") != "26.7.0"
            or set(refresh.get("pypiWheelPlatforms", [])) != {
                "macosx_13_0_arm64", "manylinux_2_34_aarch64", "manylinux_2_34_x86_64"}
            or refresh.get("androidOrIosWheels") != 0
            or refresh.get("prismMlMefArtifacts") != 0
            or not isinstance(refresh.get("demoPublicReposChecked"), int)
            or refresh["demoPublicReposChecked"] < 1
            or refresh.get("demoReposMatchingMaxMobile") != 0
            or not isinstance(refresh.get("demoPublicGistsChecked"), int)
            or refresh["demoPublicGistsChecked"] < 0):
        raise ValueError("MAX refresh evidence is incomplete or claims mobile support")
    _text(refresh.get("demoSearchScope"), 512)

    candidate = refresh.get("bonsaiTokenizerCandidate", {})
    if (candidate.get("repo") != "prism-ml/Ternary-Bonsai-2-2B-mlx-2bit"
            or candidate.get("revision") != "1c6cbae21f8c38830ce337972b46fdae7b18eaaa"
            or candidate.get("filename") != "tokenizer.json"
            or candidate.get("bytes") != 12807982
            or candidate.get("sha256") != "5f9e4d4901a92b997e463c1f46055088b6cca5ca61a6522d1b9f64c4bb81cb42"
            or candidate.get("adopted") is not False):
        raise ValueError("Bonsai tokenizer candidate must stay unadopted and pinned")
    _text(candidate.get("note"), 512)

    demo = lock.get("demonstration", {})
    if (demo.get("publicSourceAvailable") is not False
            or demo.get("independentlyReproduced") is not False):
        raise ValueError("The demonstration must stay unverified")
    if not 1 <= demo.get("reportedTokensPerSecond", 0) <= 1000:
        raise ValueError("Reported speed must be a bounded author claim")
    for key in ["reportedBy", "backendDescription", "customAdditionNote"]:
        if not _text(demo.get(key), 256).startswith("https://x.com/"):
            raise ValueError("Demonstration evidence must be the original public posts")
    _text(demo.get("note"), 512)

    artifact = lock.get("artifact", {})
    if artifact.get("mef") is not None:
        raise ValueError("No MEF is pinned or reviewed")
    if (entry.get("id") != artifact.get("modelId")
            or entry.get("filename") != artifact.get("filename")
            or entry.get("downloadBytes") != artifact.get("bytes")
            or entry.get("sha256") != artifact.get("sha256")
            or artifact.get("revision") not in entry.get("url", "")
            or artifact.get("filename") not in entry.get("url", "")):
        raise ValueError("Mobile artifact differs from the shared catalog")

    prerequisites = lock.get("prerequisites", [])
    if (len(prerequisites) != len(REQUIRED)
            or {item.get("id") for item in prerequisites} != REQUIRED
            or any(item.get("satisfied") is not False for item in prerequisites)):
        raise ValueError("Every mobile prerequisite must remain explicitly unsatisfied")
    for item in prerequisites:
        _text(item.get("detail"), 512)

    claims = lock.get("claims", {})
    if (claims.get("mobileMaxSupported") is not False
            or claims.get("bonsaiMaxGeneration") is not False
            or claims.get("automaticEligible") is not False
            or claims.get("phonePerformanceVerified") is not False
            or claims.get("storeSubmission") != "deferred"):
        raise ValueError("Unverified mobile inference or store claims are forbidden")


def main() -> None:
    lock = load_lock()
    validate(lock, catalog_entry(lock["artifact"]["modelId"]))
    print(json.dumps({
        "mobileMaxSupported": False,
        "status": lock["status"],
        "sourceRevision": lock["movement"]["sourceRevision"],
        "mobileBackendPaths": lock["movement"]["mobileBackendPaths"],
        "refreshMainRevision": lock["refresh"]["mainRevision"],
        "refreshMobileBackendPaths": lock["refresh"]["mainMobileBackendPaths"],
        "androidOrIosWheels": lock["refresh"]["androidOrIosWheels"],
        "prismMlMefArtifacts": lock["refresh"]["prismMlMefArtifacts"],
        "artifact": lock["artifact"]["filename"],
        "blockedPrerequisites": len(lock["prerequisites"]),
        "phoneValidation": "not-run",
        "storeSubmission": lock["claims"]["storeSubmission"],
    }, sort_keys=True))


if __name__ == "__main__":
    main()
