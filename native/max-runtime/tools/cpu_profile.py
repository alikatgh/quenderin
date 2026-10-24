"""Exact CPU fixture projection; imports no SDK, ELF loader or provider code."""
from __future__ import annotations

import configparser
import hashlib
import json
import os
import pathlib
import re
import stat
import time
import zipfile

PROFILE_ID = "max-26.7.0-linux-x86_64-cpu-without-nvshmem-v1"
OMITTED_PACKAGE = "max-shmem-libs"
OMITTED_MOJO = "max_mojo_libs-26.7.0.data/platlib/modular/lib/mojo/shmem.mojoc"
NVSHMEM_NAMES = {"libnvshmem_host.so.3", "nvshmem_bootstrap_mpi.so.3", "nvshmem_transport_ibgda.so.6", "nvshmem_transport_ibrc.so.6"}


def canonical_sha(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def installed_path(member: str) -> str:
    pure = pathlib.PurePosixPath(member)
    if pure.is_absolute() or ".." in pure.parts or "\\" in member or not pure.parts:
        raise ValueError("Unsafe CPU projection member")
    parts = pure.parts
    if parts[0].endswith(".data"):
        if len(parts) < 3 or parts[1] not in {"platlib", "purelib"}:
            raise ValueError("Unsupported wheel spreading scheme in CPU fixture")
        parts = parts[2:]
    return pathlib.PurePosixPath(*parts).as_posix()


def validate_profile(lock: dict, native: dict) -> dict:
    profile = lock.get("cpu_fixture_profile")
    if (not isinstance(profile, dict) or profile.get("schema") != 1 or profile.get("id") != PROFILE_ID
            or profile.get("scope") != "hosted-cpu-fixture-only-no-redistribution"
            or profile.get("omitted_packages") != [OMITTED_PACKAGE]
            or profile.get("generated_console_scripts") != "omit"
            or profile.get("runtime_license_approval_inferred") is not False):
        raise ValueError("Exact reviewed CPU fixture profile required")
    evidence = {key: value for key, value in native.items() if key != "evidenceSHA256"}
    if (canonical_sha(evidence) != native.get("evidenceSHA256")
            or native.get("evidenceSHA256") != profile.get("native_evidence_sha256")
            or native.get("sdkCodeExecuted") is not False):
        raise ValueError("CPU profile native evidence identity differs")
    expected_artifacts = [{key: package[key] for key in ["name", "version", "sha256"]} for package in lock["packages"]]
    if native.get("artifacts") != expected_artifacts:
        raise ValueError("CPU profile archive closure differs")
    fields = ["package", "path", "size", "sha256"]
    omitted = [{key: item[key] for key in fields} for item in native["elfs"] if item["package"] == OMITTED_PACKAGE]
    if (profile.get("omitted_package_payloads") != omitted or len(omitted) != 4
            or {pathlib.PurePosixPath(item["path"]).name for item in omitted} != NVSHMEM_NAMES
            or set(native.get("maxShmemPackagePayloads", [])) != {item["path"] for item in omitted}):
        raise ValueError("Exact four-file NVSHMEM package receipt required")
    wrappers = [{key: item[key] for key in fields} for item in native["sharedMemoryArtifacts"]
                if item["package"] == "max-mojo-libs" and item["path"] == OMITTED_MOJO]
    if len(wrappers) != 1 or profile.get("omitted_files") != [{**wrappers[0], "installed_path": installed_path(OMITTED_MOJO)}]:
        raise ValueError("Exact omitted shmem.mojoc receipt required")
    if any("nvshmem" in needed.lower() for item in native["elfs"] if item["package"] != OMITTED_PACKAGE for needed in item["needed"]):
        raise ValueError("Retained ELF requires the omitted NVSHMEM runtime")
    entrypoints = {"max/driver/__init__.py", "max/driver/driver.py", "max/engine/__init__.py", "max/engine/api.py", "max/graph/__init__.py"}
    observed = [item for item in native["pythonImports"] if item["package"] == "max" and item["path"] in entrypoints]
    if {item["path"] for item in observed} != entrypoints or any(item["sharedMemoryReferences"] for item in observed):
        raise ValueError("CPU entrypoint shared-memory import evidence differs")
    exception = profile.get("declared_dependency_exception", {})
    if exception.get("package") != "max-core" or exception.get("requirement") != "max-shmem-libs==26.7.0" or not exception.get("reason"):
        raise ValueError("Explicit bounded CPU dependency exception required")
    return {"profileSHA256": canonical_sha(profile), "nativeEvidenceSHA256": native["evidenceSHA256"],
            "retainedPackages": [package["name"] for package in lock["packages"] if package["name"] != OMITTED_PACKAGE],
            "omittedPackages": [OMITTED_PACKAGE], "runtimeAdmissionInferred": False}


def hash_stream(source) -> tuple[str, int]:
    digest, size = hashlib.sha256(), 0
    for chunk in iter(lambda: source.read(65536), b""):
        size += len(chunk)
        if size > 268435456:
            raise ValueError("CPU projection file exceeds 256 MiB")
        digest.update(chunk)
    return digest.hexdigest(), size


def hash_file(path: pathlib.Path) -> tuple[str, int]:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("Regular unshared CPU fixture file required")
        digest, size = hash_stream(source)
        if size != info.st_size:
            raise ValueError("CPU fixture file changed during verification")
        return digest, size


def build_projection(lock: dict, wheels: pathlib.Path, native: dict) -> dict:
    decision = validate_profile(lock, native)
    profile = lock["cpu_fixture_profile"]
    expected, distributions, scripts = {}, {}, set()
    omitted = {(item["package"], item["path"]): item for item in profile["omitted_package_payloads"] + profile["omitted_files"]}
    observed_omissions = set()
    aggregate = 0
    for package in lock["packages"]:
        path = wheels / package["filename"]
        digest, size = hash_file(path)
        if digest != package["sha256"] or size != package["size"]:
            raise ValueError("CPU projection source archive identity differs")
        with zipfile.ZipFile(path) as wheel:
            roots = {pathlib.PurePosixPath(item.filename).parts[0] for item in wheel.infolist()
                     if re.fullmatch(r"[^/]+\.dist-info/METADATA", item.filename)}
            if len(roots) != 1:
                raise ValueError("Unique CPU projection distribution required")
            dist = next(iter(roots))
            if package["name"] != OMITTED_PACKAGE:
                distributions[dist] = {"package": package["name"], "url": path.resolve().as_uri(), "sha256": package["sha256"]}
            for item in wheel.infolist():
                if item.is_dir():
                    continue
                if (item.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError("CPU projection cannot contain archive links")
                target = installed_path(item.filename)
                with wheel.open(item) as source:
                    file_sha, file_size = hash_stream(source)
                aggregate += file_size
                if file_size != item.file_size or aggregate > lock["maximum_uncompressed_bytes"]:
                    raise ValueError("CPU projection extraction budget exceeded")
                key = package["name"], item.filename
                if key in omitted:
                    record = omitted[key]
                    if file_sha != record["sha256"] or file_size != record["size"]:
                        raise ValueError("Omitted CPU component identity differs")
                    observed_omissions.add(key)
                if package["name"] == OMITTED_PACKAGE or key in omitted:
                    continue
                if target in expected:
                    raise ValueError("Overlapping CPU projection files")
                expected[target] = {"package": package["name"], "sha256": file_sha, "size": file_size,
                                    "kind": "pip-record" if target == dist + "/RECORD" else "archive"}
                if target == dist + "/entry_points.txt":
                    config = configparser.ConfigParser(interpolation=None)
                    config.optionxform = str
                    config.read_string(wheel.read(item).decode("utf-8"))
                    for group in ["console_scripts", "gui_scripts"]:
                        for name in config[group] if group in config else []:
                            if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", name):
                                raise ValueError("Unexpected generated console-script name")
                            scripts.add(name)
    if observed_omissions != set(omitted) or len(expected) > 16384 or len(scripts) > 128:
        raise ValueError("Incomplete or oversized CPU projection")
    return {**decision, "expected": expected, "distributions": distributions, "consoleScripts": sorted(scripts)}


def file_inventory(sdk: pathlib.Path, forbidden_hashes: set[str]) -> dict:
    if sdk.is_symlink() or not sdk.is_dir():
        raise ValueError("Owned CPU SDK directory required")
    result, aggregate = {}, 0
    for directory, subdirectories, filenames in os.walk(sdk, followlinks=False):
        for name in subdirectories:
            if "nvshmem" in name.lower() or "max_shmem_libs" in name.lower():
                raise ValueError("Omitted shared-memory directory is present in CPU SDK")
            if (pathlib.Path(directory) / name).is_symlink():
                raise ValueError("CPU SDK directory links are forbidden")
        for name in filenames:
            path = pathlib.Path(directory) / name
            relative = path.relative_to(sdk).as_posix()
            if "nvshmem" in relative.lower() or "max_shmem_libs" in relative.lower() or path.name == "shmem.mojoc":
                raise ValueError("Omitted shared-memory component is present in CPU SDK")
            digest, size = hash_file(path)
            if digest in forbidden_hashes:
                raise ValueError("Omitted component was renamed inside CPU SDK")
            aggregate += size
            if len(result) >= 16384 or aggregate > 1600000000:
                raise ValueError("CPU SDK installed-file budget exceeded")
            result[relative] = {"sha256": digest, "size": size}
    return result


def verify_tree(sdk: pathlib.Path, projection: dict, profile: dict) -> dict:
    forbidden = {item["sha256"] for item in profile["omitted_package_payloads"] + profile["omitted_files"]}
    actual = file_inventory(sdk, forbidden)
    expected = projection["expected"]
    if not set(expected).issubset(actual):
        raise ValueError("Retained CPU SDK file is missing")
    for path, source in expected.items():
        if source["kind"] == "archive" and actual[path] != {key: source[key] for key in ["sha256", "size"]}:
            raise ValueError(f"Retained CPU SDK file identity differs: {path}")
        if source["kind"] == "pip-record" and actual[path]["size"] > 1048576:
            raise ValueError("Installer RECORD exceeds metadata budget")
    for path in set(actual) - set(expected):
        pure = pathlib.PurePosixPath(path)
        if len(pure.parts) != 2 or pure.parts[0] not in projection["distributions"]:
            raise ValueError(f"Unexpected CPU SDK file: {path}")
        source = projection["distributions"][pure.parts[0]]
        if actual[path]["size"] > 65536:
            raise ValueError("Installer-generated CPU metadata exceeds budget")
        data = (sdk / path).read_bytes()
        if pure.name == "INSTALLER" and data == b"pip\n" or pure.name == "REQUESTED" and data == b"":
            continue
        if pure.name == "direct_url.json":
            value = json.loads(data)
            archive = value.get("archive_info", {})
            if (set(value) == {"url", "archive_info"} and value["url"] == source["url"]
                    and set(archive).issubset({"hash", "hashes"})
                    and archive.get("hashes") == {"sha256": source["sha256"]}
                    and archive.get("hash", "sha256=" + source["sha256"]) == "sha256=" + source["sha256"]):
                continue
        raise ValueError(f"Unverified installer-generated CPU SDK file: {path}")
    return actual


def prepare_installation(sdk: pathlib.Path, projection: dict, profile: dict) -> dict:
    # Only exact newly installed, session-owned fixture files are removed.
    # The original wheels and all license/notice files remain unchanged.
    for item in profile["omitted_files"]:
        path = sdk / item["installed_path"]
        if hash_file(path) != (item["sha256"], item["size"]):
            raise ValueError("Installed omitted component differs from its exact receipt")
        path.unlink()
    scripts = sdk / "bin"
    if scripts.exists():
        if scripts.is_symlink() or not scripts.is_dir():
            raise ValueError("Unexpected CPU SDK generated-script directory")
        for path in scripts.iterdir():
            if path.name not in projection["consoleScripts"]:
                raise ValueError("Unexpected CPU SDK generated script")
            _, size = hash_file(path)
            if size > 65536:
                raise ValueError("Generated CPU SDK script exceeds budget")
            path.unlink()
        scripts.rmdir()
    actual = verify_tree(sdk, projection, profile)
    return {"schema": 1, "profileSHA256": projection["profileSHA256"],
            "nativeEvidenceSHA256": projection["nativeEvidenceSHA256"],
            "sourceProjection": projection, "files": actual}


def verify_installation(sdk: pathlib.Path, manifest: dict, lock: dict, native: dict) -> None:
    decision = validate_profile(lock, native)
    projection = manifest.get("sourceProjection", {})
    if (manifest.get("schema") != 1 or any(manifest.get(key) != decision[key] or projection.get(key) != decision[key]
                                          for key in ["profileSHA256", "nativeEvidenceSHA256"])
            or projection.get("retainedPackages") != decision["retainedPackages"]):
        raise ValueError("CPU installation manifest provenance differs")
    if verify_tree(sdk, projection, lock["cpu_fixture_profile"]) != manifest.get("files"):
        raise ValueError("CPU installation manifest changed before SDK import")


def loader_directories(sdk: pathlib.Path, native: dict) -> set[pathlib.Path]:
    directories = {pathlib.Path(path) for path in ["/lib", "/lib64", "/usr/lib", "/usr/lib64", "/usr/local/lib",
                   "/lib/x86_64-linux-gnu", "/usr/lib/x86_64-linux-gnu", "/usr/local/lib/x86_64-linux-gnu",
                   "/usr/local/cuda/lib64", "/usr/local/cuda/lib", "/opt/nvshmem/lib", "/usr/local/nvshmem/lib"]}
    for item in native["elfs"]:
        if item["package"] == OMITTED_PACKAGE:
            continue
        origin = (sdk / installed_path(item["path"])).parent
        directories.add(origin)
        for value in item["rpath"] + item["runpath"]:
            for component in value.split(":"):
                expanded = component.replace("${ORIGIN}", str(origin)).replace("$ORIGIN", str(origin))
                if "$" in expanded or not expanded.startswith("/"):
                    raise ValueError("Unreviewed relative/variable ELF loader path")
                directories.add(pathlib.Path(expanded).resolve())
    return directories


def configured_loader_directories(config: pathlib.Path = pathlib.Path("/etc/ld.so.conf")) -> set[pathlib.Path]:
    directories, pending, visited = set(), [config], set()
    while pending:
        path = pending.pop()
        if path in visited:
            continue
        visited.add(path)
        if len(visited) > 64:
            raise ValueError("System loader configuration budget exceeded")
        if not path.exists():
            continue
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
            raise ValueError("Unverified system loader configuration")
        for line in path.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            if line.startswith("include "):
                pattern = line.split(None, 1)[1]
                if pattern != "/etc/ld.so.conf.d/*.conf":
                    raise ValueError("Unreviewed system loader include")
                pending.extend(sorted(pathlib.Path("/etc/ld.so.conf.d").glob("*.conf")))
            elif line.startswith("/") and not any(character in line for character in "*$\x00"):
                directories.add(pathlib.Path(line).resolve())
            else:
                raise ValueError("Unparsed system loader configuration")
    return directories


def check_loader_snapshot(cache: str, maps: str, preload: str, directory_entries: dict[str, list[str]]) -> None:
    if "nvshmem" in cache.lower() or "nvshmem" in maps.lower():
        raise ValueError("NVSHMEM is available in the system loader cache or process maps")
    if any(line.split("#", 1)[0].strip() for line in preload.splitlines()):
        raise ValueError("System-wide preloaded libraries are not admitted")
    if any("nvshmem" in name.lower() for names in directory_entries.values() for name in names):
        raise ValueError("NVSHMEM file is available on an inspected loader path")


def verify_loader_absence(sdk: pathlib.Path, native: dict, deadline: float) -> dict:
    # read-only ldconfig -p is a cache parser. Never probe absence with CDLL,
    # dlopen, ldd, an SDK executable, or an NVSHMEM initialization call.
    from run_fixture import bounded
    env = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}
    cache, _ = bounded(["/sbin/ldconfig", "-p"], env=env, cwd=sdk, deadline=deadline, max_output_bytes=1048576)
    maps_path = pathlib.Path("/proc/self/maps")
    if maps_path.stat().st_size > 1048576:
        raise ValueError("Process loader map budget exceeded")
    maps = maps_path.read_text()
    if len(maps.encode()) > 1048576:
        raise ValueError("Process loader map budget exceeded")
    preload_path = pathlib.Path("/etc/ld.so.preload")
    if preload_path.exists() and (preload_path.is_symlink() or preload_path.stat().st_size > 65536):
        raise ValueError("Unverified system preload configuration")
    preload = preload_path.read_text() if preload_path.exists() else ""
    directories = loader_directories(sdk, native) | configured_loader_directories()
    # Include versioned CUDA roots and glibc hardware-capability subdirectories
    # without recursively scanning unrelated system or user folders.
    local = pathlib.Path("/usr/local")
    local_entries = list(local.iterdir()) if local.is_dir() else []
    if len(local_entries) > 1024:
        raise ValueError("CUDA loader directory discovery budget exceeded")
    for path in local_entries:
        if path.name.startswith(("cuda-", "nvshmem")):
            directories.update([path / "lib", path / "lib64"])
    for path in list(directories):
        hwcaps = path / "glibc-hwcaps"
        if hwcaps.is_dir():
            variants = list(hwcaps.iterdir())
            if len(variants) > 32:
                raise ValueError("Loader hardware-capability directory budget exceeded")
            directories.update(variant for variant in variants if variant.is_dir())
    directories = {path.resolve() for path in directories}
    if len(directories) > 1024:
        raise ValueError("Loader search directory budget exceeded")
    entries, count = {}, 0
    for path in sorted(directories):
        if time.monotonic() >= deadline:
            raise ValueError("CPU loader absence deadline exceeded")
        if path.exists() and not path.is_dir():
            raise ValueError("Unexpected non-directory loader search path")
        names = [item.name for item in path.iterdir()] if path.exists() else []
        count += len(names)
        if len(names) > 16384 or count > 131072:
            raise ValueError("Loader directory-entry budget exceeded")
        entries[str(path)] = names
    check_loader_snapshot(cache.decode("utf-8"), maps, preload, entries)
    return {"nvshmemAvailable": False, "systemPreloadEmpty": True, "loaderCacheSHA256": hashlib.sha256(cache).hexdigest(),
            "checkedDirectories": sorted(entries), "checkedDirectoryCount": len(entries), "sdkCodeExecuted": False}
