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
import struct
import subprocess
import sys

sys.dont_write_bytecode = True
import prepare_diffusion_runtime as runtime
import verify_prism_apple_runtime as apple_runtime

ROOT = Path(__file__).resolve().parent.parent
STAMP = "quenderin-diffusion-runtime.json"
PLATFORMS = {"Windows": "win", "Linux": "linux", "Darwin": "mac"}
ARCHES = {"AMD64": "x64", "x86_64": "x64", "aarch64": "arm64", "arm64": "arm64", "armv7l": "armv7l"}

# node-llama-cpp 3.19.1 copies build/bin into build/Release and keeps both.
# Resolve the addon actually loaded by the same no-fallback CPU options as the
# mandatory Prism probe; lastBuild metadata alone is not proof of that identity.
ACTIVE_PRISM_PROBE = r'''
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile, realpath} from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const packageDir=path.resolve(process.argv[1]), revision=process.argv[2];
const readJSON=async file=>JSON.parse(await readFile(file,'utf8'));
const metadata=await readJSON(path.join(packageDir,'package.json'));
assert.equal(metadata.name,'node-llama-cpp'); assert.equal(metadata.version,'3.19.1');
const {folderName}=await readJSON(path.join(packageDir,'llama/lastBuild.json'));
assert.equal(typeof folderName,'string'); assert.match(folderName,/^[A-Za-z0-9_. -]+$/);
assert(!['.','..'].includes(folderName));
const release=path.join(packageDir,'llama/localBuilds',folderName,'Release');
const {buildOptions}=await readJSON(path.join(release,'_nlcBuildMetadata.json'));
assert.deepEqual(buildOptions.llamaCpp,{repo:'PrismML-Eng/llama.cpp',release:revision});
assert.equal(buildOptions.gpu,false);
assert.equal(buildOptions.arch,process.arch);
assert.equal(buildOptions.platform,({win32:'win',linux:'linux',darwin:'mac'})[process.platform]);
const {getBuildFolderNameForBuildOptions}=await import(pathToFileURL(path.join(packageDir,'dist/bindings/utils/getBuildFolderNameForBuildOptions.js')));
const computed=await getBuildFolderNameForBuildOptions({...buildOptions,customCmakeOptions:new Map(Object.entries(buildOptions.customCmakeOptions))});
assert.equal(computed.withCustomCmakeOptions,folderName);
const {getLlama}=await import(pathToFileURL(path.join(packageDir,'dist/index.js')));
const loaded=[], original=process.dlopen;
process.dlopen=function(module, filename, ...args) {
    if(path.basename(filename)==='llama-addon.node') loaded.push(path.resolve(filename));
    return original.call(this,module,filename,...args);
};
let llama;
try {
    llama=await getLlama({gpu:false,build:'never',usePrebuiltBinaries:false,skipDownload:true,progressLogs:false,maxThreads:2});
    assert.equal(llama.buildType,'localBuild');
    assert.deepEqual(llama.llamaCppRelease,buildOptions.llamaCpp);
    assert.equal(loaded.length,1,'Expected exactly one actually loaded local Prism addon');
    const addonPath=await realpath(loaded[0]);
    assert.equal(addonPath,await realpath(path.join(release,'llama-addon.node')),'Loaded addon differs from active lastBuild');
    for(const [type,size] of [[142,34],[143,28]]) {
        assert.equal(llama._bindings.getBlockSizeForGgmlType(type),128);
        assert.equal(llama._bindings.getTypeSizeForGgmlType(type),size);
    }
    assert.equal(llama._bindings.getQuenderinWeeklyTextRuntimeABI(),1);
    console.log(JSON.stringify({folderName,addonPath,addonSha256:createHash('sha256').update(await readFile(addonPath)).digest('hex'),binVariant:computed.binVariant}));
} finally {
    process.dlopen=original;
    if(llama) await llama.dispose();
}
'''


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


def macho_payloads(directory):
    """Seal executable section identities, independent of code-signing bytes."""
    return {name: apple_runtime.macho_payload(directory / name) for name in names("mac")}


def linux_dependencies(output):
    result = {}
    for line in output.splitlines():
        if "not found" in line:
            raise ValueError("Unresolved Linux runtime dependency")
        match = re.fullmatch(r"\s*(\S+)\s+=>\s+(/.+)\s+\(0x[0-9A-Fa-f]+\)\s*", line)
        if match:
            result[match[1]] = Path(match[2].rstrip())
        elif line.strip() and not re.fullmatch(r"\s*(?:linux-vdso\S*|/.+)\s+\(0x[0-9A-Fa-f]+\)\s*", line):
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
    if os_name == "mac":
        payloads = data.get("machoPayloads")
        if not isinstance(payloads, dict) or set(payloads) != set(names("mac")):
            raise ValueError("Image runtime seal is missing Mach-O payload identities")
        valid_files = all(key in actual and key in expected and "sha256" in actual[key]
                          for key in names("mac"))
        try:
            actual_payloads = macho_payloads(directory) if valid_files else None
        except (ValueError, struct.error) as error:
            raise ValueError("Image runtime seal mismatch: Mach-O executable payload changed") from error
        if actual_payloads != payloads:
            raise ValueError("Image runtime seal mismatch: Mach-O executable payload changed")
        # Signing changes the whole-file digests, never the sealed loaded code,
        # UUID, platform or minimum OS. All other resource bytes remain exact;
        # only the framework's CodeResources signature may be added/replaced.
        if packaged:
            for key in names("mac"):
                actual[key] = expected[key]
            signature = "QuenderinDiffusion.framework/Versions/A/_CodeSignature/CodeResources"
            if signature in actual and "sha256" in actual[signature]:
                actual.pop(signature)
                expected = {key: value for key, value in expected.items() if key != signature}
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
    if os_name == "mac":
        seal["machoPayloads"] = macho_payloads(destination)
    (destination / STAMP).write_text(json.dumps(seal, indent=2, sort_keys=True) + "\n")
    return verify(destination)


def probe_active_prism(package, revision):
    try:
        output = run(["node", "--input-type=module", "-e", ACTIVE_PRISM_PROBE, package, revision], timeout=60)
    except subprocess.CalledProcessError as error:
        raise ValueError("Active Prism addon probe failed: " + (error.stderr or error.stdout or "no diagnostic")[-3000:]) from error
    except subprocess.SubprocessError as error:
        raise ValueError("Active Prism addon probe did not finish within its bound") from error
    try:
        return json.loads(output)
    except json.JSONDecodeError as error:
        raise ValueError("Active Prism addon probe did not return its identity JSON") from error


def active_prism_libraries(prism):
    """Select dependencies beside the proven active Release/llama-addon.node.

    CMake's retained bin copies are accepted only when byte-identical to that
    active artifact. Other build folders never participate in selection.
    """
    if not prism.is_dir() or prism.is_symlink() or prism.name != "localBuilds" or prism.parent.name != "llama":
        raise ValueError("Joint load requires node-llama-cpp/llama/localBuilds with active lastBuild.json metadata")
    prism = prism.resolve()
    package = prism.parent.parent
    metadata = json.loads((package / "package.json").read_text())
    if (metadata.get("name"), metadata.get("version")) != ("node-llama-cpp", "3.19.1"):
        raise ValueError("Joint load requires the exact node-llama-cpp 3.19.1 layout")
    last_build = json.loads((prism.parent / "lastBuild.json").read_text())
    folder = last_build.get("folderName")
    if not isinstance(folder, str) or not re.fullmatch(r"[A-Za-z0-9_. -]+", folder) or folder in (".", ".."):
        raise ValueError("Invalid active Prism lastBuild folderName")
    active = prism / folder
    release = active / "Release"
    if not release.is_dir() or active.is_symlink() or release.is_symlink() or not release.resolve().is_relative_to(prism):
        raise ValueError(f"Active Prism Release directory is missing or unsafe: {folder}/Release")
    for file in (active / "buildDone.status", release / "llama-addon.node", release / "_nlcBuildMetadata.json"):
        if not file.is_file() or file.is_symlink():
            raise ValueError(f"Active Prism build is incomplete or unsafe: {file.relative_to(prism)}")
    options = json.loads((release / "_nlcBuildMetadata.json").read_text()).get("buildOptions", {})
    lock = json.loads((ROOT / "shared/prism-runtime.json").read_text())
    if (options.get("platform"), options.get("arch"), options.get("llamaCpp"), options.get("gpu") is False) != (
            *host(), {"repo": "PrismML-Eng/llama.cpp", "release": lock["revision"]}, True):
        raise ValueError("Active Prism build metadata does not match the pinned CPU platform/architecture/revision")
    probe = probe_active_prism(package, lock["revision"])
    addon = release / "llama-addon.node"
    if probe.get("folderName") != folder or Path(probe.get("addonPath", "")).resolve() != addon.resolve() or probe.get("addonSha256") != sha(addon):
        raise ValueError("Actually loaded Prism addon does not match the active build path and digest")
    variant = probe.get("binVariant")
    expected_variant = "PrismML-Eng_llama.cpp_" + lock["revision"]
    if not isinstance(variant, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", variant) or not (
            variant == expected_variant or variant.startswith(expected_variant + ".")):
        raise ValueError("Active Prism binary variant does not identify the pinned source")
    os_name, _ = host()
    prefix, suffix = ("", ".dll") if os_name == "win" else ("lib", ".dylib" if os_name == "mac" else ".so")
    libraries = [release / (prefix + "ggml-base" + suffix), release / (prefix + "llama." + variant + suffix)]
    for library in libraries:
        if not library.is_file() or not library.resolve().is_relative_to(release):
            raise ValueError(f"Active Prism dependency is missing or unsafe beside the loaded addon: {library.name}")
        identity = sha(library)
        copies = []
        for source in (active / "bin", active / "llama.cpp/bin"):
            if source.is_symlink() or (source.exists() and not source.resolve().is_relative_to(active)):
                raise ValueError("Unsafe retained active Prism dependency directory")
            if source.is_dir():
                copies.extend(source.rglob(library.name))
        if len(copies) > 64:
            raise ValueError(f"Too many retained active-build copies to verify: {library.name}")
        for copy in copies:
            if not copy.is_file() or not copy.resolve().is_relative_to(active) or sha(copy) != identity:
                raise ValueError(f"Mismatched retained active Prism dependency copy: {copy.relative_to(active)}")
    return {"ggml": libraries[0].resolve(), "llama": libraries[1].resolve(),
            "folderName": folder, "addonSha256": probe["addonSha256"]}


def joint_load(directory, prism):
    """No weights: prove both GGML ABIs remain usable in one process, both orders."""
    selected = active_prism_libraries(prism)
    # Each order runs in a fresh child so an already loaded DSO cannot hide a bug.
    for order in ("prism-first", "image-first"):
        run([sys.executable, __file__, "joint-child", "--directory", directory,
             "--prism-library", selected["ggml"], "--llama-library", selected["llama"], "--order", order], timeout=30, capture=False)
    return {"jointLoad": True, "orders": 2, "weightsLoaded": False,
            "activePrismBuild": selected["folderName"], "addonSha256": selected["addonSha256"]}


def joint_child(directory, prism_library, llama_library, order):
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
            if llama_library.parent != prism_library.parent:
                raise ValueError("Joint load requires both Prism dependencies beside the same active addon")
            llama = ctypes.CDLL(str(llama_library), mode=getattr(ctypes, "RTLD_GLOBAL", 0))
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
    p = commands.add_parser("joint-child"); p.add_argument("--directory", type=Path, required=True); p.add_argument("--prism-library", type=Path, required=True); p.add_argument("--llama-library", type=Path, required=True); p.add_argument("--order", choices=("prism-first", "image-first"), required=True)
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
            joint_child(args.directory, args.prism_library, args.llama_library, args.order); result = {"order": args.order, "passed": True}
        print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Desktop diffusion gate failed: {error}\n")


if __name__ == "__main__":
    main()
