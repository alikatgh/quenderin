#!/usr/bin/env python3
"""Build/seal/probe the pinned, isolated desktop image runtime. Never fetch weights.

Build only on the target OS/architecture. Packaging consumes this sealed directory;
it must not download a fallback runtime or substitute another architecture.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
import prepare_diffusion_runtime as runtime

ROOT = Path(__file__).resolve().parent.parent
STAMP = "quenderin-diffusion-runtime.json"
PLATFORMS = {"Windows": "win", "Linux": "linux", "Darwin": "mac"}
ARCHES = {"AMD64": "x64", "x86_64": "x64", "aarch64": "arm64", "arm64": "arm64", "armv7l": "armv7l"}


def host():
    try:
        return PLATFORMS[platform.system()], ARCHES[platform.machine()]
    except KeyError as error:
        raise ValueError("Unsupported desktop build host") from error


def run(args, *, timeout=120, capture=True):
    result = subprocess.run([str(a) for a in args], check=True, text=True,
                            capture_output=capture, timeout=timeout)
    return result.stdout if capture else ""


def windows_tools():
    """Use already-installed VS tools, without invoking a shell or dumping its env."""
    if platform.system() != "Windows" or shutil.which("dumpbin"):
        return
    base = os.environ.get("ProgramFiles(x86)")
    if not base:
        raise ValueError("Visual Studio tools are unavailable")
    vswhere = Path(base) / "Microsoft Visual Studio/Installer/vswhere.exe"
    installation = run([vswhere, "-latest", "-products", "*", "-requires",
                        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"]).strip()
    candidates = sorted((Path(installation) / "VC/Tools/MSVC").glob("*/bin/Hostx64/x64/dumpbin.exe"))
    if not candidates:
        raise ValueError("dumpbin is required to verify Windows exports/dependencies")
    os.environ["PATH"] = str(candidates[-1].parent) + os.pathsep + os.environ.get("PATH", "")


def names(os_name):
    return ("quenderin-diffusion-cli.exe", "quenderin_diffusion.dll") if os_name == "win" else (
        "quenderin-diffusion-cli", "QuenderinDiffusion.framework/Versions/A/QuenderinDiffusion" if os_name == "mac" else "libquenderin_diffusion.so")


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inventory(directory):
    result = {}
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory).as_posix()
        if relative == STAMP:
            continue
        if any(part.startswith(".") for part in path.relative_to(directory).parts):
            raise ValueError("Hidden files are forbidden in runtime resources")
        if path.is_symlink():
            target = os.readlink(path)
            if Path(target).is_absolute() or not path.resolve(strict=True).is_relative_to(directory.resolve()):
                raise ValueError("Runtime symlink escapes its resource directory")
            result[relative] = {"symlink": target}
        elif path.is_file():
            result[relative] = {"bytes": path.stat().st_size, "sha256": sha(path)}
        elif not path.is_dir():
            raise ValueError("Runtime resources must be ordinary files/directories")
    return result


def linux_dependencies(output):
    result = {}
    for line in output.splitlines():
        if "not found" in line:
            raise ValueError("Unresolved Linux runtime dependency")
        match = re.match(r"\s*(\S+)\s+=>\s+(/\S+)\s+\(", line)
        if match:
            result[match[1]] = Path(match[2])
        elif line.strip() and not re.match(r"\s*(?:linux-vdso\S*|/\S+)\s+\(", line):
            raise ValueError("Unrecognized Linux dependency output")
    return result


def dependency_check(directory, os_name, *, bundle=False):
    """The single private DSO contains SD+GGML; no backend/plugin DLL is allowed."""
    cli_name, library_name = names(os_name)
    binaries = [directory / cli_name, directory / library_name]
    if os_name == "linux":
        allowed_system = re.compile(r"^(?:lib(?:c|m|pthread|dl|rt)\.so(?:\.\d+)*|ld-linux[^/]*)$")
        for binary in binaries:
            dependencies = linux_dependencies(run(["ldd", binary]))
            for name, source in dependencies.items():
                if name == "libquenderin_diffusion.so":
                    if source.resolve() != binaries[1].resolve():
                        raise ValueError("CLI resolved a different diffusion DSO")
                elif name in {"libstdc++.so.6", "libgcc_s.so.1"}:
                    target = directory / name
                    if bundle and not target.exists():
                        shutil.copy2(source.resolve(), target)
                    if not target.is_file() or (not bundle and source.resolve() != target.resolve()):
                        raise ValueError("C++ runtime dependency must resolve inside diffusion resources")
                elif not allowed_system.fullmatch(name):
                    raise ValueError(f"Unexpected private/system dependency: {name}")
        if bundle:
            for package in ("libstdc++6", "libgcc-s1"):
                license_file = Path("/usr/share/doc") / package / "copyright"
                if not license_file.is_file():
                    raise ValueError("GNU runtime redistribution notice is unavailable")
                shutil.copyfile(license_file, directory / (package + "-copyright.txt"))
    elif os_name == "win":
        windows_tools()
        system = Path(os.environ["SystemRoot"]) / "System32"
        for binary in binaries:
            output = run(["dumpbin", "/NOLOGO", "/DEPENDENTS", binary])
            dependencies = re.findall(r"^\s+([A-Za-z0-9_.-]+\.dll)\s*$", output, re.MULTILINE | re.IGNORECASE)
            if not dependencies:
                raise ValueError("Could not inspect PE dependencies")
            for name in dependencies:
                lower = name.lower()
                if lower == "quenderin_diffusion.dll":
                    if binary == binaries[1]:
                        raise ValueError("Diffusion DLL unexpectedly depends on itself")
                elif lower.startswith(("vcruntime", "msvcp", "libgcc", "libstdc++")):
                    raise ValueError("Desktop Windows image runtime must use the static C++ CRT")
                elif not lower.startswith(("api-ms-win-", "ext-ms-win-")) and not (system / name).is_file():
                    raise ValueError(f"Unresolved non-system Windows dependency: {name}")
    else:
        for binary in binaries:
            for line in run(["otool", "-L", binary]).splitlines()[1:]:
                name = line.strip().split(" (", 1)[0]
                if name.startswith(("/usr/lib/", "/System/Library/")):
                    continue
                if "QuenderinDiffusion.framework/Versions/A/QuenderinDiffusion" in name and name.startswith("@rpath/"):
                    continue
                raise ValueError(f"Unexpected macOS image runtime dependency: {name}")


def verify(directory, *, os_name=None, arch=None, packaged=False):
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError("Build/stage the pinned image runtime before packaging")
    lock, _ = runtime.manifests()
    data = json.loads((directory / STAMP).read_text())
    expected_os, expected_arch = host()
    os_name, arch = os_name or expected_os, arch or expected_arch
    if (data.get("version"), data.get("abiVersion"), data.get("revision"), data.get("platform"), data.get("arch")) != (
            1, lock["abiVersion"], lock["revision"], os_name, arch):
        raise ValueError("Image runtime source/ABI/target provenance mismatch")
    if (os_name, arch) != host():
        raise ValueError("Verify the image runtime on its target OS/architecture")
    actual = inventory(directory)
    expected = data.get("files")
    if not isinstance(expected, dict) or not expected:
        raise ValueError("Image runtime seal is empty")
    # Signing changes Mach-O bytes and adds framework signature resources. The
    # exact pre-sign payload is checked in beforePack and afterPack; final probes
    # still verify the pinned C ABI, exports and dependency closure after signing.
    if packaged and os_name == "mac":
        actual = {k: v for k, v in actual.items() if "/_CodeSignature/" not in k}
        for key in names(os_name):
            if key in actual and key in expected:
                actual[key] = expected[key]
    if actual != expected:
        raise ValueError("Image runtime seal mismatch (missing, extra or modified file)")
    cli, library = (directory / name for name in names(os_name))
    windows_tools()
    runtime.verify_library(library, {"win": "windows", "mac": "apple", "linux": "elf"}[os_name])
    version = json.loads(run([cli, "--version"]))
    if version != {"abiVersion": lock["abiVersion"], "revision": lock["revision"]}:
        raise ValueError("Image CLI reports a different pinned runtime")
    dependency_check(directory, os_name)
    return {"platform": os_name, "arch": arch, **version, "files": len(expected)}


def build(work, destination):
    os_name, arch = host()
    if not work.is_absolute() or work.exists() or destination.exists() or destination.is_symlink():
        raise ValueError("Build work and staging destinations must be new; work must be absolute")
    if shutil.disk_usage(work.parent).free < 6 * 1024 ** 3:
        raise ValueError("Desktop image compilation requires at least 6 GiB free")
    work.mkdir()
    runtime.fetch(work / "source")
    flags = ["-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
             "-DCMAKE_BUILD_RPATH_USE_ORIGIN=ON"]
    if os_name == "linux":
        flags += ["-DCMAKE_BUILD_RPATH=$ORIGIN"]
    if os_name == "win":
        flags += ["-A", {"x64": "x64", "arm64": "ARM64"}[arch]]
    elif os_name == "mac":
        flags += ["-DCMAKE_OSX_DEPLOYMENT_TARGET=13.3", "-DCMAKE_OSX_ARCHITECTURES=" + {"x64": "x86_64", "arm64": "arm64"}[arch]]
    run(["cmake", "-S", ROOT / "native/diffusion", "-B", work / "build",
         "-DDIFFUSION_SOURCE_DIR=" + str(work / "source"), *flags], timeout=180, capture=False)
    run(["cmake", "--build", work / "build", "--config", "Release", "--parallel", "2"], timeout=1800, capture=False)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.mkdir()
    cli, library = names(os_name)
    shutil.copy2(work / "build/bin" / cli, destination / cli)
    if os_name == "mac":
        shutil.copytree(work / "build/bin/QuenderinDiffusion.framework", destination / "QuenderinDiffusion.framework", symlinks=True)
    else:
        shutil.copy2(work / "build/bin" / library, destination / library)
    shutil.copyfile(work / "source/LICENSE", destination / "stable-diffusion-LICENSE.txt")
    shutil.copyfile(work / "source/ggml/LICENSE", destination / "ggml-LICENSE.txt")
    dependency_check(destination, os_name, bundle=True)
    lock, _ = runtime.manifests()
    seal = {"version": 1, "abiVersion": lock["abiVersion"], "revision": lock["revision"],
            "platform": os_name, "arch": arch, "files": inventory(destination)}
    (destination / STAMP).write_text(json.dumps(seal, indent=2, sort_keys=True) + "\n")
    return verify(destination)


def joint_load(directory, prism):
    """No weights: prove both GGML ABIs remain usable in one process, both orders."""
    os_name, _ = host()
    library = directory / names(os_name)[1]
    suffix = {"win": r"\.dll", "mac": r"\.dylib", "linux": r"\.so(?:\.\d+)*"}[os_name]
    candidates = sorted({p.resolve() for p in prism.rglob("*ggml-base*")
                         if p.is_file() and re.search(suffix + "$", p.name, re.IGNORECASE)})
    if len(candidates) != 1:
        raise ValueError("Joint load requires exactly one actual Prism ggml-base library")
    # Each order runs in a fresh child so an already loaded DSO cannot hide a bug.
    for order in ("prism-first", "image-first"):
        run([sys.executable, __file__, "joint-child", "--directory", directory,
             "--prism-library", candidates[0], "--order", order], timeout=30, capture=False)
    return {"jointLoad": True, "orders": 2, "weightsLoaded": False}


def joint_child(directory, prism_library, order):
    image_path = directory / names(host()[0])[1]
    # Windows resolves the compiled Prism dependency closure in this directory.
    dll_directory = os.add_dll_directory(str(prism_library.parent)) if os.name == "nt" else None
    try:
        def load_image():
            image = ctypes.CDLL(str(image_path), mode=getattr(ctypes, "RTLD_GLOBAL", 0))
            image.quenderin_diffusion_revision.restype = ctypes.c_char_p
            lock, _ = runtime.manifests()
            if image.quenderin_diffusion_abi() != lock["abiVersion"] or image.quenderin_diffusion_revision().decode() != lock["revision"]:
                raise ValueError("Joint-loaded image ABI/source mismatch")
            return image
        def load_prism():
            ggml = ctypes.CDLL(str(prism_library), mode=getattr(ctypes, "RTLD_GLOBAL", 0))
            ggml.ggml_type_size.argtypes = [ctypes.c_int]
            ggml.ggml_type_size.restype = ctypes.c_size_t
            ggml.ggml_blck_size.argtypes = [ctypes.c_int]
            ggml.ggml_blck_size.restype = ctypes.c_int64
            suffix = {"win": r"\.dll", "mac": r"\.dylib", "linux": r"\.so(?:\.\d+)*"}[host()[0]]
            libraries = {p.resolve() for p in prism_library.parent.glob("*llama*")
                         if p.is_file() and re.search(suffix + "$", p.name, re.IGNORECASE)}
            if len(libraries) != 1:
                raise ValueError("Joint load requires the actual Prism llama DSO beside ggml-base")
            llama = ctypes.CDLL(str(libraries.pop()), mode=getattr(ctypes, "RTLD_GLOBAL", 0))
            if llama.quenderin_weekly_text_runtime_abi() != 1 or llama.quenderin_muse_spark_runtime_abi() != 1:
                raise ValueError("Joint-loaded Prism llama capabilities are missing")
            return ggml, llama
        if order == "image-first":
            image = load_image(); ggml, llama = load_prism()
        else:
            ggml, llama = load_prism(); image = load_image()
        for kind, size in ((142, 34), (143, 28)):
            if ggml.ggml_type_size(kind) != size or ggml.ggml_blck_size(kind) != 128:
                raise ValueError("Prism ternary GGML ABI changed after joint image load")
        handle = image.quenderin_diffusion_create
        handle.restype = ctypes.c_void_p
        instance = handle()
        if not instance:
            raise ValueError("Joint image handle allocation failed")
        image.quenderin_diffusion_destroy.argtypes = [ctypes.c_void_p]
        if image.quenderin_diffusion_destroy(instance) != 0:
            raise ValueError("Joint image handle destruction failed")
    finally:
        if dll_directory:
            dll_directory.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("build"); p.add_argument("--work", type=Path, required=True); p.add_argument("--destination", type=Path)
    p = commands.add_parser("verify"); p.add_argument("--directory", type=Path, required=True); p.add_argument("--platform", choices=("win", "linux", "mac")); p.add_argument("--arch", choices=("x64", "arm64", "armv7l")); p.add_argument("--packaged", action="store_true")
    p = commands.add_parser("joint-load"); p.add_argument("--directory", type=Path, required=True); p.add_argument("--prism", type=Path, required=True)
    p = commands.add_parser("joint-child"); p.add_argument("--directory", type=Path, required=True); p.add_argument("--prism-library", type=Path, required=True); p.add_argument("--order", choices=("prism-first", "image-first"), required=True)
    args = parser.parse_args()
    try:
        if args.command == "build":
            destination = args.destination or ROOT / "build/diffusion" / "-".join(host())
            result = build(args.work, destination)
        elif args.command == "verify":
            result = verify(args.directory, os_name=args.platform, arch=args.arch, packaged=args.packaged)
        elif args.command == "joint-load":
            result = joint_load(args.directory, args.prism)
        else:
            joint_child(args.directory, args.prism_library, args.order); result = {"order": args.order, "passed": True}
        print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Desktop diffusion gate failed: {error}\n")


if __name__ == "__main__":
    main()
