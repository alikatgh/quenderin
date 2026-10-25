"""Nonexecuting inspection of exact hosted wheels using the system readelf.

No SDK module, ELF, compiler, or loader is executed. Temporary ELF data is mode
0600 and is passed only to /usr/bin/readelf. Never replace this with ldd.
"""
from __future__ import annotations

import ast
import hashlib
import json
import pathlib
import re
import tempfile
import time
import zipfile

from run_fixture import bounded

FAMILY = {"max", "max-core", "max-mojo-libs", "max-shmem-libs", "mojo-compiler", "mojo-compiler-mojo-libs"}
ENTRYPOINTS = {"max/__init__.py", "max/driver/__init__.py", "max/driver/driver.py",
               "max/engine/__init__.py", "max/engine/api.py", "max/graph/__init__.py"}
MARKER = re.compile(r"nvshmem|rocshmem|max[-_]shmem|\bshmem\b", re.IGNORECASE)


def parse_readelf(text: str) -> dict:
    if "ELF Header:" not in text or "Machine:" not in text:
        raise ValueError("readelf did not report an ELF header")
    values = {"needed": [], "soname": [], "rpath": [], "runpath": []}
    for line in text.splitlines():
        for tag, field in [("NEEDED", "needed"), ("SONAME", "soname"), ("RPATH", "rpath"), ("RUNPATH", "runpath")]:
            if f"({tag})" in line:
                match = re.search(r"\[([^\]\n]{1,4096})\]\s*$", line)
                if not match:
                    raise ValueError(f"Unparsed ELF dynamic {tag} entry")
                values[field].append(match[1])
    machine = re.search(r"^\s*Machine:[ \t]*([^\n]+)$", text, re.MULTILINE)
    if not machine or not machine[1].strip():
        raise ValueError("readelf did not report a valid ELF machine")
    return {"machine": machine[1].strip(), **values}


def python_evidence(package: str, member: str, raw: bytes) -> dict | None:
    text = raw.decode("utf-8")
    tree = ast.parse(text, filename=member)
    entrypoint = member in ENTRYPOINTS or package == "mojo-compiler"
    references = [{"line": number, "text": line[:240]} for number, line in enumerate(text.splitlines(), 1) if MARKER.search(line)]
    if len(references) > 128:
        raise ValueError("Python shared-memory reference evidence exceeds 128 lines/file")
    if not entrypoint and not references:
        return None
    imports = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imports.extend(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            imports.append("." * node.level + (node.module or ""))
    if len(imports) > 512:
        raise ValueError("Python import evidence exceeds 512 imports/file")
    return {"package": package, "path": member, "sha256": hashlib.sha256(raw).hexdigest(),
            "entrypoint": entrypoint, "imports": sorted(set(imports)), "sharedMemoryReferences": references}


def inspect_native(lock: dict, wheel_dir: pathlib.Path, scratch: pathlib.Path) -> dict:
    """Inspect every ELF, named shmem artifact and Modular Python import text.
    All budgets are additional restrictions within the locked extraction bound.
    """
    scratch.mkdir(mode=0o700)
    deadline = time.monotonic() + 90
    env = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "HOME": str(scratch), "TMPDIR": str(scratch)}
    version, _ = bounded(["/usr/bin/readelf", "--version"], env=env, cwd=scratch, deadline=deadline)
    elfs, python, shmem, package_payloads = [], [], [], {}
    extracted_bytes = python_bytes = reference_lines = 0
    try:
        for package in lock["packages"]:
            if time.monotonic() >= deadline:
                raise ValueError("Aggregate native metadata audit deadline exceeded")
            path = wheel_dir / package["filename"]
            digest = hashlib.sha256()
            with path.open("rb") as source:
                for chunk in iter(lambda: source.read(65536), b""):
                    digest.update(chunk)
            if path.stat().st_size != package["size"] or digest.hexdigest() != package["sha256"]:
                raise ValueError("Native audit wheel identity differs")
            with zipfile.ZipFile(path) as wheel:
                payloads = []
                for member in wheel.infolist():
                    if time.monotonic() >= deadline:
                        raise ValueError("Aggregate native metadata audit deadline exceeded")
                    if member.is_dir():
                        continue
                    pure = pathlib.PurePosixPath(member.filename)
                    if pure.is_absolute() or ".." in pure.parts or "\\" in member.filename:
                        raise ValueError("Unsafe native archive member")
                    is_payload = not any(part.endswith(".dist-info") for part in pure.parts)
                    if is_payload:
                        payloads.append(member.filename)
                    if package["name"] in FAMILY and member.filename.endswith(".py"):
                        python_bytes += member.file_size
                        if member.file_size > 1048576 or python_bytes > 33554432:
                            raise ValueError("Python import text budget exceeded")
                        evidence = python_evidence(package["name"], member.filename, wheel.read(member))
                        if evidence:
                            reference_lines += len(evidence["sharedMemoryReferences"])
                            python.append(evidence)
                            if reference_lines > 1024 or len(python) > 256:
                                raise ValueError("Python import evidence aggregate budget exceeded")
                    with wheel.open(member) as source:
                        magic = source.read(4)
                    named_shmem = bool(MARKER.search(member.filename))
                    if magic != b"\x7fELF" and not named_shmem:
                        continue
                    extracted_bytes += member.file_size
                    if (member.file_size > 268435456 or extracted_bytes > min(1073741824, lock["maximum_uncompressed_bytes"])
                            or len(elfs) >= 256):
                        raise ValueError("Native audit extraction budget exceeded")
                    artifact_digest = hashlib.sha256()
                    markers = {"nvshmem": 0, "rocshmem": 0}
                    carry = b""
                    with tempfile.NamedTemporaryFile(dir=scratch, prefix="inert-", suffix=".elf", delete=True) as temporary:
                        with wheel.open(member) as source:
                            for chunk in iter(lambda: source.read(65536), b""):
                                if time.monotonic() >= deadline:
                                    raise ValueError("Aggregate native metadata audit deadline exceeded")
                                artifact_digest.update(chunk)
                                temporary.write(chunk)
                                block = carry + chunk.lower()
                                for token in markers:
                                    markers[token] += sum(match.end() > len(carry) for match in re.finditer(token.encode(), block))
                                carry = block[-7:]
                        temporary.flush()
                        record = {"package": package["name"], "path": member.filename, "size": member.file_size,
                                  "sha256": artifact_digest.hexdigest(), "sharedMemoryByteMarkers": markers}
                        if magic == b"\x7fELF":
                            output, _ = bounded(["/usr/bin/readelf", "--wide", "--file-header", "--dynamic", temporary.name],
                                                env=env, cwd=scratch, deadline=deadline)
                            elfs.append({**record, **parse_readelf(output.decode("utf-8"))})
                        if named_shmem:
                            shmem.append(record)
                if package["name"] == "max-shmem-libs":
                    package_payloads[package["name"]] = payloads
        blockers = [{"package": item["package"], "path": item["path"], "needed": needed}
                    for item in elfs if item["package"] != "max-shmem-libs"
                    for needed in item["needed"] if "nvshmem" in needed.lower()]
        facts = {"schema": 1, "readelfVersion": version.decode("utf-8").splitlines()[0],
                 "artifacts": [{key: package[key] for key in ["name", "version", "sha256"]} for package in lock["packages"]],
                 "elfs": elfs, "pythonImports": python, "sharedMemoryArtifacts": shmem,
                 "maxShmemPackagePayloads": package_payloads.get("max-shmem-libs", []),
                 "retainedDirectNvshmemDependencyBlockers": blockers,
                 "extractedBytes": extracted_bytes, "pythonTextBytes": python_bytes,
                 "sdkCodeExecuted": False, "cpuOmissionAdmitted": False,
                 "limitations": ["DT_NEEDED cannot exclude dlopen or statically linked code.",
                                 "Python imports are parsed as text and never executed.",
                                 "Any CPU omission requires exact profile review and a pre-import installed-file gate."]}
        encoded = json.dumps(facts, sort_keys=True, separators=(",", ":")).encode()
        if len(encoded) > 524288:
            raise ValueError("Native audit evidence exceeds 512 KiB")
        return {**facts, "evidenceSHA256": hashlib.sha256(encoded).hexdigest()}
    finally:
        scratch.rmdir()
