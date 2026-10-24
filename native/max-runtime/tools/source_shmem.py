"""Rebuild the upstream Apache/LLVM module without GPU bitcode or host data.
Only the already pinned compiler is invoked, by the offline bounded supervisor.
"""
import hashlib
import pathlib
import re
import shutil

from cpu_profile import canonical_sha, hash_file, verify_tree

SOURCE_NAMES = ["__init__.mojo", "_mpi.mojo", "_nvshmem.mojo", "_rocshmem.mojo", "ep.mojo", "ep_comm.mojo",
                "shmem_api.mojo", "shmem_buffer.mojo", "shmem_context.mojo"]
MODULE_INPUTS = ["std.mojoc", "max.mojoc", "layout.mojoc", "linalg.mojoc", "structured_kernels.mojoc",
                 "_cublas.mojoc", "_rocblas.mojoc", "comm.mojoc", "internal_utils.mojoc", "pipeline.mojoc"]
IGNORED = ["UnsafePointer", "alloc", "Pointer.__add__", "Pointer.__sub__", "Pointer.__iadd__", "Pointer.__isub__",
           "Pointer.__getitem__", "Pointer.load", "Pointer.store", "Pointer.free", "Pointer.bitcast",
           "Pointer.address_space_cast", "LayoutTensor", "LayoutTensorIter"]
ARGUMENTS = ["precompile", "-strip-file-prefix=.", "-o", "{output}"] + ["--ignore-deprecated=" + name for name in IGNORED] + ["-I", "{inputs}", "{sources}"]
MODULE_PATH = "modular/lib/mojo/shmem.mojoc"


def validate_recipe(profile):
    recipe = profile.get("generated_source_module", {})
    revision = "527d069ee11a41ac5320af1f9402db0a66b2b868"
    sources = recipe.get("sources", [])
    compiler = recipe.get("compiler", {})
    if (recipe.get("schema") != 1 or recipe.get("installed_path") != MODULE_PATH
            or recipe.get("source_revision") != revision or recipe.get("source_license") != "Apache-2.0 WITH LLVM-exception"
            or recipe.get("module_inputs") != MODULE_INPUTS or recipe.get("arguments") != ARGUMENTS
            or [source.get("filename") for source in sources] != SOURCE_NAMES
            or sum(source.get("size", 0) for source in sources) != 474306
            or compiler.get("package") != "mojo-compiler" or compiler.get("version") != "1.2.0"
            or compiler.get("installed_path") != "modular/bin/mojo"
            or not re.fullmatch(r"[a-f0-9]{64}", compiler.get("sha256", ""))
            or type(compiler.get("size")) is not int or not 1 <= compiler["size"] <= 268435456):
        raise ValueError("Exact bounded upstream source-precompile recipe required")
    for source in sources:
        if (source.get("url") != f"https://raw.githubusercontent.com/modular/modular/{revision}/max/kernels/src/shmem/{source['filename']}"
                or type(source.get("size")) is not int or not 1 <= source["size"] <= 1048576
                or not re.fullmatch(r"[a-f0-9]{64}", source.get("sha256", ""))):
            raise ValueError("Unpinned Apache/LLVM source input")
    return recipe


def input_receipts(recipe, projection):
    expected = projection["expected"]
    result = []
    for name in recipe["module_inputs"]:
        path = "modular/lib/mojo/" + name
        source = expected.get(path, {})
        if source.get("kind") != "archive":
            raise ValueError("Pinned precompile dependency module is missing")
        result.append({"path": path, "sha256": source["sha256"], "size": source["size"]})
    compiler = recipe["compiler"]
    source = expected.get(compiler["installed_path"], {})
    if any(source.get(key) != compiler[key] for key in ["sha256", "size"]):
        raise ValueError("Pinned source-precompile compiler receipt differs")
    return result


def generation_files(profile, projection, receipts):
    if not receipts:
        return {}
    recipe = validate_recipe(profile)
    if len(receipts) != 1:
        raise ValueError("Exactly one generated upstream module receipt required")
    receipt = receipts[0]
    sources = [{key: source[key] for key in ["filename", "sha256", "size"]} for source in recipe["sources"]]
    output = receipt.get("output", {})
    forbidden = {item["sha256"] for item in profile["omitted_package_payloads"] + profile["omitted_files"]}
    if (receipt.get("recipeSHA256") != canonical_sha(recipe) or receipt.get("compiler") != recipe["compiler"]
            or receipt.get("sourceProjectionSHA256") != canonical_sha(projection)
            or receipt.get("arguments") != ARGUMENTS or receipt.get("sourceInputs") != sources
            or receipt.get("moduleInputs") != input_receipts(recipe, projection)
            or receipt.get("compilerExitCode") != 0 or receipt.get("sdkPythonImported") is not False
            or output.get("path") != MODULE_PATH or output.get("sha256") in forbidden
            or not re.fullmatch(r"[a-f0-9]{64}", output.get("sha256", ""))
            or type(output.get("size")) is not int or not 4 <= output["size"] <= 67108864):
        raise ValueError("Generated source module attestation differs")
    return {MODULE_PATH: {key: output[key] for key in ["sha256", "size"]}}


def generate_module(work, sdk, scratch, manifest, profile, env, deadline, run):
    recipe = validate_recipe(profile)
    projection = manifest["sourceProjection"]
    inputs = input_receipts(recipe, projection)
    source_root = work / "cpu-sources/shmem"
    if source_root.is_symlink() or {path.name for path in source_root.iterdir()} != set(SOURCE_NAMES):
        raise ValueError("Exact nine-file source closure required")
    for source in recipe["sources"]:
        path = source_root / source["filename"]
        if hash_file(path) != (source["sha256"], source["size"]):
            raise ValueError("Source-precompile input identity differs")
        with path.open("rb") as stream:
            if b"Licensed under the Apache License v2.0 with LLVM Exceptions" not in stream.read(650):
                raise ValueError("Pinned upstream source license header missing")
    compiler = recipe["compiler"]
    if hash_file(sdk / compiler["installed_path"]) != (compiler["sha256"], compiler["size"]):
        raise ValueError("Source-precompile executable identity differs")
    include = scratch / "shmem-inputs"
    include.mkdir(mode=0o700)
    for item in inputs:
        if hash_file(sdk / item["path"]) != (item["sha256"], item["size"]):
            raise ValueError("Source-precompile dependency identity differs")
        shutil.copyfile(sdk / item["path"], include / pathlib.PurePosixPath(item["path"]).name)
        if hash_file(include / pathlib.PurePosixPath(item["path"]).name) != (item["sha256"], item["size"]):
            raise ValueError("Staged source-precompile dependency differs")
    output = scratch / "source-shmem.mojoc"
    if output.exists() or (sdk / MODULE_PATH).exists():
        raise ValueError("Generated module destination must be new")
    values = {"output": str(output), "inputs": str(include), "sources": str(source_root)}
    command = [str(sdk / compiler["installed_path"])] + [arg.format(**values) for arg in ARGUMENTS]
    run(command, env=env, cwd=scratch, deadline=deadline)
    if {path.name for path in source_root.iterdir()} != set(SOURCE_NAMES):
        raise ValueError("Source closure changed during precompile")
    for source in recipe["sources"]:
        if hash_file(source_root / source["filename"]) != (source["sha256"], source["size"]):
            raise ValueError("Source input changed during precompile")
    for item in inputs:
        if hash_file(include / pathlib.PurePosixPath(item["path"]).name) != (item["sha256"], item["size"]):
            raise ValueError("Dependency input changed during precompile")
    if hash_file(sdk / compiler["installed_path"]) != (compiler["sha256"], compiler["size"]):
        raise ValueError("Compiler changed during precompile")
    digest, size = hash_file(output)
    if not 4 <= size <= 67108864:
        raise ValueError("Generated module output exceeds existing file budget")
    with output.open("rb") as stream:
        if stream.read(4) == b"\x7fELF":
            raise ValueError("Precompile output must be a data module, not an ELF")
    receipt = {"recipeSHA256": canonical_sha(recipe), "compiler": compiler, "arguments": ARGUMENTS,
               "sourceProjectionSHA256": canonical_sha(projection),
               "executedCommandSHA256": canonical_sha(command), "compilerExitCode": 0, "sdkPythonImported": False,
               "sourceInputs": [{key: source[key] for key in ["filename", "sha256", "size"]} for source in recipe["sources"]],
               "moduleInputs": inputs, "output": {"path": MODULE_PATH, "sha256": digest, "size": size}}
    generation_files(profile, projection, [receipt])
    with output.open("rb") as source, (sdk / MODULE_PATH).open("xb") as target:
        shutil.copyfileobj(source, target, 65536)
    updated = dict(manifest, generatedModules=[receipt])
    updated["files"] = verify_tree(sdk, projection, profile, [receipt])
    return updated, receipt
