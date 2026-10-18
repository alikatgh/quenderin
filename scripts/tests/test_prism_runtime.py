"""Failure tests for exact source patch provenance; no downloads or runtime builds."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("prism_runtime", Path(__file__).resolve().parents[1] / "prepare_prism_runtime.py")
prism = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prism)


class WeeklyNemotronRouterRegressionTests(unittest.TestCase):
    def test_actual_cpp_resolves_user_descriptors_and_indexed_file_tensors(self):
        """Run the real dimension-resolution block against the loader's two modes.

        The pinned user-model loader has no weights_map: its router dimensions
        exist only in GGUF descriptors. File loads index tensors across shards.
        Hosted decode/save-roundtrip still verifies the complete GGML graph.
        """
        weekly = prism.load_weekly_text_patch()
        model = next(entry for entry in weekly['files'] if entry['path'] == 'src/models/nemotron-h.cpp')
        body = next(item['after'] for item in model['replacements'] if 'router_meta' in item['after'])
        compiler = shutil.which('clang++') or shutil.which('g++')
        self.assertIsNotNone(compiler, 'C++ compiler required for the bounded router fixture')
        fixture = r'''
#include <array>
#include <cassert>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>
struct ggml_tensor { int64_t ne[4]; };
struct gguf_context {
    std::string name;
    std::array<int64_t, 4> ne;
    int reads = 0;
};
static int64_t gguf_find_tensor(gguf_context * ctx, const char * name) {
    ++ctx->reads;
    return ctx->name == name ? 0 : -1;
}
static const int64_t * gguf_get_tensor_ne(const gguf_context * ctx, int64_t tid) {
    assert(tid == 0); return ctx->ne.data();
}
struct loader {
    std::vector<int> files;
    gguf_context * metadata;
    const ggml_tensor * indexed = nullptr;
    // Same lookup behavior as the pinned get_tensor_meta: only file weights
    // enter weights_map; supplied user GGUF descriptors never enter it.
    const ggml_tensor * get_tensor_meta(const char *) const { return indexed; }
};
enum { LLM_TENSOR_FFN_GATE_INP };
struct tensor_name { std::string value; std::string str() const { return value; } };
static tensor_name tn(int, const char *, int i) {
    return {"blk." + std::to_string(i) + ".ffn_gate_inp.weight"};
}
static std::pair<int64_t, int64_t> resolve(loader & ml, int i, int64_t active, int64_t width) {
    const int64_t n_embd = 256, n_expert = 12;
    struct {
        std::array<int64_t, 4> n_expert_weekly_used_arr{0, 0, 0, 0};
        std::array<int64_t, 4> n_ff_weekly_exp_arr{0, 0, 0, 0};
        int64_t n_ff(int) const { return 384; }
    } hparams;
    hparams.n_expert_weekly_used_arr[i] = active;
    hparams.n_ff_weekly_exp_arr[i] = width;
''' + body + r'''
    return {n_expert_layer, n_ff_exp};
}
int main() {
    // Unchanged hosted fixture: layer 2 has 12/9 experts and layer 3 has 10/6.
    for (int i : {2, 3}) {
        gguf_context metadata{"blk." + std::to_string(i) + ".ffn_gate_inp.weight",
                              {256, i == 2 ? 12 : 10, 1, 1}};
        loader user{{}, &metadata};
        const auto result = resolve(user, i, i == 2 ? 9 : 6, i == 2 ? 384 : 448);
        assert(result.first == (i == 2 ? 12 : 10));
        assert(result.second == (i == 2 ? 384 : 448));
    }
    // An indexed tensor wins over main-file descriptors (including split files).
    gguf_context metadata{"blk.3.ffn_gate_inp.weight", {256, 12, 1, 1}};
    ggml_tensor indexed{{256, 10, 1, 1}};
    loader file{{1}, &metadata, &indexed};
    assert(resolve(file, 3, 6, 448).first == 10 && metadata.reads == 0);
    // Legacy generated models without descriptors retain the global shape.
    gguf_context missing{"", {0, 0, 0, 0}};
    loader generated{{}, &missing};
    assert(resolve(generated, 3, 6, 448).first == 12);
    // Never consult main-file metadata to invent a missing indexed file tensor.
    loader absent_file{{1}, &metadata};
    assert(resolve(absent_file, 3, 6, 448).first == 12 && metadata.reads == 0);
    for (auto dimensions : {std::array<int64_t, 4>{255, 10, 1, 1},
                            {256, 10, 2, 1}, {256, 10, 1, 2},
                            {256, 13, 1, 1}, {256, 5, 1, 1}, {256, 0, 1, 1}}) {
        metadata.ne = dimensions;
        loader invalid{{}, &metadata};
        bool rejected = false;
        try { resolve(invalid, 3, 6, 448); } catch (const std::runtime_error &) { rejected = true; }
        assert(rejected);
    }
}
'''
        with tempfile.TemporaryDirectory(prefix='weekly-nemotron-router-') as scratch:
            binary = Path(scratch) / 'router-fixture'
            result = subprocess.run([compiler, '-std=c++17', '-O0', '-x', 'c++', '-', '-o', str(binary)],
                                    input=fixture, text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr[-8000:])
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr[-8000:])


class WeeklyMoeAggregationRegressionTests(unittest.TestCase):
    def test_actual_cpp_reduction_handles_heterogeneous_topk_and_preserves_warmup_cap(self):
        """Exercise the real patched block, with GGML view bounds and numeric sums.

        The original block must reproduce the six-selected/nine-global failure.
        This tiny tensor API needs no GGML build, model data or accelerator.
        The existing heterogeneous Nemotron decode/save-roundtrip fixture remains
        the full graph regression check in hosted CI.
        """
        weekly = prism.load_weekly_text_patch()
        graph = next(entry for entry in weekly['files'] if entry['path'] == 'src/llama-graph.cpp')
        replacement = next(item for item in graph['replacements'] if 'cur_experts[LLAMA_MAX_EXPERTS]' in item['before'])
        compiler = shutil.which('clang++') or shutil.which('g++')
        self.assertIsNotNone(compiler, 'C++ compiler required for the bounded graph-reduction fixture')
        fixture = r'''
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <utility>
#include <vector>
#define LLAMA_MAX_EXPERTS 256
#define GGML_ASSERT(value) do { if (!(value)) throw std::runtime_error("graph assertion"); } while (0)
struct ggml_tensor {
    int64_t ne[4];
    size_t nb[4];
    std::vector<float> values;
    bool contiguous;
};
static std::vector<std::unique_ptr<ggml_tensor>> storage;
static ggml_tensor * tensor(int64_t width, int64_t selected, int64_t tokens) {
    auto value = std::make_unique<ggml_tensor>();
    value->ne[0]=width; value->ne[1]=selected; value->ne[2]=tokens; value->ne[3]=1;
    value->nb[0]=sizeof(float); value->nb[1]=width*sizeof(float);
    value->nb[2]=width*selected*sizeof(float); value->nb[3]=width*selected*tokens*sizeof(float);
    value->values.resize(width*selected*tokens); value->contiguous=true;
    ggml_tensor * result=value.get(); storage.push_back(std::move(value)); return result;
}
static ggml_tensor * ggml_view_2d(void *, ggml_tensor * source, int64_t width, int64_t tokens, size_t stride, size_t offset) {
    if (offset + width*sizeof(float) + (tokens-1)*stride > source->values.size()*sizeof(float)) {
        throw std::out_of_range("expert view exceeds selected expert tensor");
    }
    ggml_tensor * out=tensor(width,tokens,1);
    out->contiguous=stride==width*sizeof(float);
    for (int64_t token=0; token<tokens; ++token) {
        for (int64_t index=0; index<width; ++index) {
            out->values[token*width+index]=source->values[(offset+token*stride)/sizeof(float)+index];
        }
    }
    return out;
}
static ggml_tensor * ggml_add(void *, ggml_tensor * a, ggml_tensor * b) {
    GGML_ASSERT(a->values.size()==b->values.size());
    ggml_tensor * out=tensor(a->ne[0],a->ne[1],a->ne[2]);
    for (size_t index=0; index<a->values.size(); ++index) out->values[index]=a->values[index]+b->values[index];
    return out;
}
static ggml_tensor * ggml_cont(void *, ggml_tensor * source) {
    ggml_tensor * out=tensor(source->ne[0],source->ne[1],source->ne[2]);
    out->values=source->values; return out;
}
static void ggml_build_forward_expand(void *, ggml_tensor *) {}
static void cb(ggml_tensor *, const char *, int) {}
'''
        for name, body in (('original', replacement['before']), ('fixed', replacement['after'])):
            fixture += '\nstatic ggml_tensor * ' + name + r'''(ggml_tensor * experts, int64_t n_expert_used, uint32_t global_active) {
    struct { uint32_t n_expert_used; } hparams{global_active};
    void * ctx0=nullptr; void * gf=nullptr; int il=0;
    const int64_t n_embd=experts->ne[0], n_tokens=experts->ne[2];
''' + body + '\n}\n'
        fixture += r'''
int main() {
    // Match Nemotron's second MoE block: six selected, global maximum nine.
    bool reproduced=false;
    try { original(tensor(7,6,3),6,9); } catch (const std::out_of_range &) { reproduced=true; }
    GGML_ASSERT(reproduced);
    // Homogeneous top-k, smaller per-layer top-k, warmup selecting every expert,
    // and a single selected expert that must return a contiguous output.
    for (auto counts : {std::pair<int64_t,uint32_t>{9,9}, {6,9}, {12,9}, {1,9}, {1,1}}) {
        storage.clear();
        const int64_t selected=counts.first, width=7, tokens=3;
        ggml_tensor * experts=tensor(width,selected,tokens);
        for (int64_t token=0; token<tokens; ++token)
            for (int64_t expert=0; expert<selected; ++expert)
                for (int64_t index=0; index<width; ++index)
                    experts->values[(token*selected+expert)*width+index]=float(expert+1);
        ggml_tensor * out=fixed(experts,selected,counts.second);
        const int64_t used=std::min<int64_t>(selected,counts.second);
        const float expected=float(used*(used+1)/2);
        GGML_ASSERT(out->values.size()==size_t(width*tokens) && out->contiguous);
        for (float value : out->values) GGML_ASSERT(value==expected);
    }
}
'''
        with tempfile.TemporaryDirectory(prefix='weekly-moe-reduction-') as scratch:
            binary = Path(scratch) / 'aggregation-fixture'
            result = subprocess.run([compiler, '-std=c++17', '-O0', '-x', 'c++', '-', '-o', str(binary)],
                                    input=fixture, text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr[-8000:])
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr[-8000:])


class PrismRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="prism-source-test-")
        self.addCleanup(self.scratch.cleanup)
        self.project = Path(self.scratch.name) / "project"
        self.root = Path(self.scratch.name) / "source"
        (self.project / "scripts/patches").mkdir(parents=True)
        (self.root / "ggml/include").mkdir(parents=True)
        (self.root / "src/models").mkdir(parents=True)
        self.before = 'get_key("prism.hadamard.version")\nold\n'
        self.after = self.before.replace("old", "new")
        self.new = "synthetic Muse source\n"
        self.lock = copy.deepcopy(prism.LOCK)
        self.lock.pop("weeklyTextPatch", None)
        self.lock.pop("beamPatch", None)
        self.manifest = {
            "version": 1, "id": self.lock["sourcePatch"]["id"],
            "baseRepository": self.lock["repository"], "baseRevision": self.lock["revision"],
            "upstreamRevision": self.lock["sourcePatch"]["upstreamRevision"],
            "museSparkABI": 1, "capabilitySymbol": "quenderin_muse_spark_runtime_abi",
            "files": [
                {"path": "src/llama-model.cpp", "beforeSha256": prism.digest(self.before.encode()),
                 "afterSha256": prism.digest(self.after.encode()),
                 "replacements": [{"before": "old\n", "after": "new\n"}]},
                {"path": "src/models/muse-spark.cpp", "beforeSha256": None,
                 "afterSha256": prism.digest(self.new.encode()), "content": self.new},
            ],
        }
        self.save_manifest()
        (self.root / "ggml/include/ggml.h").write_text("GGML_TYPE_PTQ1_0 GGML_TYPE_PQ2_0")
        (self.root / "src/llama-model.cpp").write_text(self.before)
        for name, value in (("ROOT", self.project), ("LOCK", self.lock)):
            p = patch.object(prism, name, value)
            p.start()
            self.addCleanup(p.stop)
        p = patch.object(prism, "git", side_effect=self.git)
        self.real_git = prism.git
        p.start()
        self.addCleanup(p.stop)

    def save_manifest(self):
        path = self.project / self.lock["sourcePatch"]["path"]
        data = (json.dumps(self.manifest) + "\n").encode()
        path.write_bytes(data)
        self.lock["sourcePatch"]["sha256"] = prism.digest(data)

    def git(self, source, *args):
        if args[0] == "rev-parse":
            return self.lock["revision"]
        if args[0] == "config":
            return self.lock["repository"]
        if args[0] == "status":
            return (" M src/llama-model.cpp\n?? src/models/muse-spark.cpp"
                    if (source / "src/models/muse-spark.cpp").exists() else "")
        raise AssertionError(args)

    def ready(self):
        return prism.apply_source_patch(self.root)

    def test_patch_is_exact_and_idempotent_and_old_base_is_not_supported(self):
        with self.assertRaisesRegex(ValueError, "missing or modified"):
            prism.verify(self.root)
        identity = self.ready()
        self.assertEqual(identity["sourcePatchSha256"], self.lock["sourcePatch"]["sha256"])
        self.assertEqual(identity["museSparkABI"], 1)
        self.assertEqual((self.root / "src/llama-model.cpp").read_text(), self.after)
        self.assertEqual(prism.apply_source_patch(self.root), identity)
        self.assertEqual(prism.verify(self.root), identity)

    def test_wrong_revision_origin_and_unknown_source_changes_rejected(self):
        self.ready()
        for field, value in (("rev-parse", "wrong"), ("config", "wrong"),
                             ("status", "?? src/models/injected.cpp"),
                             ("status", "M  src/llama-model.cpp")):
            with self.subTest(field=field, value=value):
                def git(source, *args):
                    return value if args[0] == field else self.git(source, *args)
                with patch.object(prism, "git", side_effect=git), self.assertRaises(ValueError):
                    prism.verify(self.root)

    def test_output_tamper_and_missing_file_fail_with_same_base_revision(self):
        self.ready()
        source = self.root / "src/models/muse-spark.cpp"
        source.write_text("tampered")
        with self.assertRaisesRegex(ValueError, "missing or modified"):
            prism.verify(self.root)
        source.unlink()
        with self.assertRaisesRegex(ValueError, "missing or modified"):
            prism.verify(self.root)

    def test_missing_ternary_or_hadamard_is_not_a_capability(self):
        self.ready()
        (self.root / "ggml/include/ggml.h").write_text("stock types")
        with self.assertRaisesRegex(ValueError, "Hadamard"):
            prism.verify(self.root)

    def test_manifest_digest_and_identity_are_bound(self):
        path = self.project / self.lock["sourcePatch"]["path"]
        path.write_text(path.read_text() + " ")
        with self.assertRaisesRegex(ValueError, "digest"):
            prism.apply_source_patch(self.root)
        self.manifest["museSparkABI"] = 2
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "identity"):
            prism.apply_source_patch(self.root)
        self.assertEqual((self.root / "src/llama-model.cpp").read_text(), self.before)

    def test_all_outputs_validated_before_any_write(self):
        self.manifest["files"][1]["content"] = "invalid output"
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "output digest"):
            prism.apply_source_patch(self.root)
        self.assertEqual((self.root / "src/llama-model.cpp").read_text(), self.before)
        self.assertFalse((self.root / "src/models/muse-spark.cpp").exists())

    def test_preimage_mismatch_preserves_existing_user_changes(self):
        source = self.root / "src/llama-model.cpp"
        source.write_text("user source")
        with self.assertRaisesRegex(ValueError, "preimage differs"):
            prism.apply_source_patch(self.root)
        self.assertEqual(source.read_text(), "user source")

    def test_traversal_duplicate_and_symlink_are_rejected_before_writes(self):
        original = copy.deepcopy(self.manifest)
        for name in ("../outside.cpp", "/tmp/outside.cpp", "src/../outside.cpp"):
            self.manifest = copy.deepcopy(original)
            self.manifest["files"][1]["path"] = name
            self.save_manifest()
            with self.assertRaisesRegex(ValueError, "path"):
                prism.apply_source_patch(self.root)
        self.manifest = copy.deepcopy(original)
        self.manifest["files"].append(copy.deepcopy(self.manifest["files"][0]))
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "duplicated"):
            prism.apply_source_patch(self.root)
        self.manifest = original
        self.save_manifest()
        outside = self.project / "user-source.cpp"
        outside.write_text(self.before)
        source = self.root / "src/llama-model.cpp"
        source.unlink()
        source.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "escapes"):
            prism.apply_source_patch(self.root)
        self.assertEqual(outside.read_text(), self.before)

    def test_declared_origin_survives_transport_rewrite(self):
        with patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0"}):
            subprocess.run(["git", "init", "--quiet", str(self.root)], check=True, capture_output=True)
            self.real_git(self.root, "config", "--local", "remote.origin.url", self.lock["repository"])
            self.real_git(self.root, "config", "--local", "url.http://cloud-mirror.invalid/github/.insteadOf", "https://github.com/")
            self.assertIn("cloud-mirror", self.real_git(self.root, "remote", "get-url", "origin"))

            def transport_git(source, *args):
                return self.real_git(source, *args) if args[0] == "config" else self.git(source, *args)
            with patch.object(prism, "git", side_effect=transport_git):
                self.ready()
                self.real_git(self.root, "config", "--local", "remote.origin.url", "https://untrusted.invalid/runtime.git")
                with self.assertRaisesRegex(ValueError, "origin"):
                    prism.verify(self.root)

    def test_fetch_preserves_existing_path(self):
        original = self.root / "user-file"
        original.write_text("preserve me")
        with patch.object(prism.subprocess, "run") as run, self.assertRaisesRegex(ValueError, "already exists"):
            prism.fetch(self.root)
        run.assert_not_called()
        self.assertEqual(original.read_text(), "preserve me")

    def test_commit_io_failure_restores_original_and_retry_succeeds(self):
        real_link = prism.os.link
        new_file = self.root / "src/models/muse-spark.cpp"
        def fail_new(source, destination, **kwargs):
            if Path(destination) == new_file.resolve():
                raise OSError("injected disk exhaustion")
            return real_link(source, destination, **kwargs)
        with patch.object(prism.os, "link", side_effect=fail_new), self.assertRaisesRegex(OSError, "disk exhaustion"):
            prism.apply_source_patch(self.root)
        self.assertEqual((self.root / "src/llama-model.cpp").read_text(), self.before)
        self.assertFalse(new_file.exists())
        self.assertEqual(list(self.root.parent.glob(".quenderin-runtime-patch-*")), [])
        self.ready()

    def test_recovery_inspection_failure_retains_original_links(self):
        original = self.root / "src/llama-model.cpp"
        new_file = self.root / "src/models/muse-spark.cpp"
        real_link, real_read = prism.os.link, Path.read_bytes
        failing = False
        def fail_new(source, destination, **kwargs):
            nonlocal failing
            if Path(destination) == new_file.resolve():
                failing = True
                raise OSError("injected commit failure")
            return real_link(source, destination, **kwargs)
        def fail_inspection(path):
            if failing and path == original.resolve(): raise PermissionError("injected recovery read failure")
            return real_read(path)
        with patch.object(prism.os, "link", side_effect=fail_new), patch.object(Path, "read_bytes", fail_inspection):
            with self.assertRaisesRegex(ValueError, "preserved original links"):
                prism.apply_source_patch(self.root)
        retained = list(self.root.parent.glob(".quenderin-runtime-patch-*"))
        self.assertEqual(len(retained), 1)
        self.assertEqual((retained[0] / "0.before").read_text(), self.before)

    def test_stamp_requires_muse_header_in_every_slice_and_binds_identity(self):
        identity = self.ready()
        artifact = self.project / "new.xcframework"
        headers = artifact / "macos/llama.framework/Headers"
        headers.mkdir(parents=True)
        (headers / "ggml.h").write_text("GGML_TYPE_PTQ1_0 GGML_TYPE_PQ2_0")
        with self.assertRaisesRegex(ValueError, "Muse capability"):
            prism.stamp(self.root, artifact)
        self.assertFalse((artifact / prism.STAMP).exists())
        (headers / "llama.h").write_text("int quenderin_muse_spark_runtime_abi(void);")
        self.assertEqual(prism.stamp(self.root, artifact), identity)
        self.assertEqual(json.loads((artifact / prism.STAMP).read_text()), identity)


class PrismCheckoutLineEndingsTests(unittest.TestCase):
    def test_runtime_fetch_preserves_pinned_bytes_with_windows_git_defaults(self):
        with tempfile.TemporaryDirectory(prefix="prism-checkout-test-") as scratch:
            root = Path(scratch)
            seed, destination = root / "seed", root / "runtime"
            global_config = root / "gitconfig"
            global_config.write_text("[core]\n\tautocrlf = true\n")
            with patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": str(global_config),
                                         "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0"}):
                def run(*args):
                    return subprocess.check_output(["git", *args], text=True, stderr=subprocess.STDOUT).strip()

                run("init", "--quiet", "--initial-branch=main", str(seed))
                run("-C", str(seed), "config", "core.autocrlf", "false")
                (seed / "model.cpp").write_bytes(b"pinned source\nsecond line\n")
                (seed / "scripts/patches").mkdir(parents=True)
                manifest = b'{"version": 1}\n'
                (seed / "scripts/patches/runtime.json").write_bytes(manifest)
                (seed / ".gitattributes").write_bytes((prism.ROOT / ".gitattributes").read_bytes())
                run("-C", str(seed), "add", "model.cpp", "scripts/patches/runtime.json", ".gitattributes")
                run("-C", str(seed), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                    "commit", "--quiet", "-m", "Pinned fixture")
                lock = {"branch": "main", "repository": str(seed),
                        "revision": run("-C", str(seed), "rev-parse", "HEAD")}
                default_checkout = root / "default-checkout"
                run("clone", "--quiet", str(seed), str(default_checkout))
                self.assertEqual((default_checkout / "scripts/patches/runtime.json").read_bytes(), manifest)
                self.assertIn(b"\r\n", (default_checkout / "model.cpp").read_bytes())

                def verify_bytes(source):
                    self.assertEqual((source / "model.cpp").read_bytes(), b"pinned source\nsecond line\n")
                    return {"verified": True}

                with patch.object(prism, "LOCK", lock), patch.object(prism, "apply_source_patch", side_effect=verify_bytes):
                    self.assertEqual(prism.fetch(destination), {"verified": True})


class WeeklyTextPatchTests(unittest.TestCase):
    """Exercise ordered composition independently of actual model source text."""

    def setUp(self):
        self.fixture = PrismRuntimeTests(methodName="test_fetch_preserves_existing_path")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        f = self.fixture
        self.weekly_after = f.after.replace("new", "weekly")
        self.new_content = "weekly text source\n"
        self.manifest = {
            "version": 1, "id": "weekly-text-fixture",
            "baseRepository": f.lock["repository"], "baseRevision": f.lock["revision"],
            "parentSourcePatch": {"id": f.lock["sourcePatch"]["id"], "sha256": f.lock["sourcePatch"]["sha256"]},
            "upstreamRevisions": {"k2Horizon": "a" * 40, "nemotron35": "b" * 40},
            "weeklyTextABI": 1, "capabilitySymbol": "quenderin_weekly_text_runtime_abi",
            "files": [
                {"path": "src/llama-model.cpp", "beforeSha256": prism.digest(f.after.encode()),
                 "afterSha256": prism.digest(self.weekly_after.encode()),
                 "replacements": [{"before": "new\n", "after": "weekly\n"}]},
                {"path": "src/models/weekly.cpp", "beforeSha256": None,
                 "afterSha256": prism.digest(self.new_content.encode()), "content": self.new_content},
            ],
        }
        self.path = f.project / "scripts/patches/weekly.json"
        f.lock["weeklyTextPatch"] = {
            "id": self.manifest["id"], "path": "scripts/patches/weekly.json", "sha256": "",
            "weeklyTextABI": 1, "upstreamRevisions": self.manifest["upstreamRevisions"],
        }
        self.save()

        def git(source, *args):
            result = f.git(source, *args)
            if args[0] == "status" and (source / "src/models/weekly.cpp").exists():
                result += "\n?? src/models/weekly.cpp"
            return result
        p = patch.object(prism, "git", side_effect=git)
        p.start()
        self.addCleanup(p.stop)

    def save(self):
        data = (json.dumps(self.manifest) + "\n").encode()
        self.path.write_bytes(data)
        self.fixture.lock["weeklyTextPatch"]["sha256"] = prism.digest(data)

    def test_both_stages_are_atomic_exact_and_idempotent(self):
        f = self.fixture
        identity = prism.apply_source_patch(f.root)
        self.assertEqual((f.root / "src/llama-model.cpp").read_text(), self.weekly_after)
        self.assertEqual(identity["sourcePatchId"], f.manifest["id"])
        self.assertEqual(identity["weeklyTextABI"], 1)
        self.assertEqual(identity["weeklyTextPatchSha256"], f.lock["weeklyTextPatch"]["sha256"])
        self.assertEqual(prism.verify(f.root), identity)
        self.assertEqual(prism.apply_source_patch(f.root), identity)

    def test_second_stage_output_failure_writes_neither_stage(self):
        self.manifest["files"][1]["content"] = "wrong output"
        self.save()
        with self.assertRaisesRegex(ValueError, "output digest"):
            prism.apply_source_patch(self.fixture.root)
        self.assertEqual((self.fixture.root / "src/llama-model.cpp").read_text(), self.fixture.before)
        self.assertFalse((self.fixture.root / "src/models/muse-spark.cpp").exists())

    def test_wrong_parent_or_order_is_rejected_before_writes(self):
        original = copy.deepcopy(self.manifest)
        for mutation in ("parent", "preimage", "symbol", "revision", "abi", "path"):
            self.manifest = copy.deepcopy(original)
            if mutation == "parent":
                self.manifest["parentSourcePatch"]["sha256"] = "c" * 64
            elif mutation == "preimage":
                self.manifest["files"][0]["beforeSha256"] = "d" * 64
            elif mutation == "symbol":
                self.manifest["capabilitySymbol"] = "untrusted_symbol"
            elif mutation == "revision":
                self.manifest["upstreamRevisions"]["k2Horizon"] = "latest"
            elif mutation == "abi":
                self.manifest["weeklyTextABI"] = True
            elif mutation == "path":
                self.manifest["files"][1]["path"] = "ggml/../outside.cpp"
            self.save()
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                prism.apply_source_patch(self.fixture.root)
            self.assertEqual((self.fixture.root / "src/llama-model.cpp").read_text(), self.fixture.before)

    def test_partial_install_and_tampered_final_source_are_preserved(self):
        f = self.fixture
        # A Muse-only checkout is not silently updated in place.
        identity = f.lock.pop("weeklyTextPatch")
        prism.apply_source_patch(f.root)
        f.lock["weeklyTextPatch"] = identity
        with self.assertRaisesRegex(ValueError, "Existing source changes"):
            prism.apply_source_patch(f.root)
        self.assertEqual((f.root / "src/llama-model.cpp").read_text(), f.after)
        self.assertFalse((f.root / "src/models/weekly.cpp").exists())

    def test_artifact_stamp_requires_both_exported_capability_headers(self):
        f = self.fixture
        identity = prism.apply_source_patch(f.root)
        artifact = f.project / "weekly.xcframework"
        headers = artifact / "macos/llama.framework/Headers"
        headers.mkdir(parents=True)
        (headers / "ggml.h").write_text("GGML_TYPE_PTQ1_0 GGML_TYPE_PQ2_0")
        llama_header = headers / "llama.h"
        llama_header.write_text("int quenderin_muse_spark_runtime_abi(void);")
        with self.assertRaisesRegex(ValueError, "weekly text capability"):
            prism.stamp(f.root, artifact)
        self.assertFalse((artifact / prism.STAMP).exists())
        llama_header.write_text(llama_header.read_text() + "\nint quenderin_weekly_text_runtime_abi(void);")
        self.assertEqual(prism.stamp(f.root, artifact), identity)


class BeamPatchTests(unittest.TestCase):
    """A third stage cannot borrow weekly text capability or bypass stack identity."""

    def setUp(self):
        self.weekly = WeeklyTextPatchTests(methodName="test_both_stages_are_atomic_exact_and_idempotent")
        self.weekly.setUp()
        self.addCleanup(self.weekly.doCleanups)
        f = self.fixture = self.weekly.fixture
        self.after = self.weekly.weekly_after.replace("weekly", "beam")
        self.manifest = {
            "version": 1, "id": "beam-fixture", "baseRepository": f.lock["repository"],
            "baseRevision": f.lock["revision"],
            "parentSourcePatch": {k: f.lock["sourcePatch"][k] for k in ("id", "sha256")},
            "parentWeeklyTextPatch": {k: f.lock["weeklyTextPatch"][k] for k in ("id", "sha256")},
            "upstreamRevision": "e" * 40, "beamABI": 1,
            "capabilitySymbol": "quenderin_beam_runtime_abi",
            "files": [
                {"path": "src/llama-model.cpp", "beforeSha256": prism.digest(self.weekly.weekly_after.encode()),
                 "afterSha256": prism.digest(self.after.encode()),
                 "replacements": [{"before": "weekly\n", "after": "beam\n"}]},
                {"path": "src/models/beam.cpp", "beforeSha256": None,
                 "afterSha256": prism.digest(b"Beam graph fixture\n"), "content": "Beam graph fixture\n"},
            ],
        }
        f.lock["beamPatch"] = {"id": self.manifest["id"], "path": "scripts/patches/beam.json",
                               "sha256": "", "upstreamRevision": self.manifest["upstreamRevision"], "beamABI": 1}
        self.save()
        previous_git = prism.git

        def git(source, *args):
            result = previous_git(source, *args)
            if args[0] == "status" and (source / "src/models/beam.cpp").exists():
                result += "\n?? src/models/beam.cpp"
            return result
        p = patch.object(prism, "git", side_effect=git)
        p.start()
        self.addCleanup(p.stop)

    def save(self):
        f = self.fixture
        data = (json.dumps(self.manifest) + "\n").encode()
        (f.project / f.lock["beamPatch"]["path"]).write_bytes(data)
        f.lock["beamPatch"]["sha256"] = prism.digest(data)

    def test_third_stage_is_exact_and_idempotent_and_has_its_own_identity(self):
        f = self.fixture
        identity = prism.apply_source_patch(f.root)
        self.assertEqual((f.root / "src/llama-model.cpp").read_text(), self.after)
        self.assertEqual(identity["beamABI"], 1)
        self.assertEqual(identity["beamPatchSha256"], f.lock["beamPatch"]["sha256"])
        self.assertEqual(identity["weeklyTextPatchSha256"], f.lock["weeklyTextPatch"]["sha256"])
        self.assertEqual(prism.verify(f.root), identity)
        self.assertEqual(prism.apply_source_patch(f.root), identity)

    def test_third_stage_output_failure_writes_none_of_the_stages(self):
        self.manifest["files"][1]["content"] = "invalid output"
        self.save()
        with self.assertRaisesRegex(ValueError, "output digest"):
            prism.apply_source_patch(self.fixture.root)
        self.assertEqual((self.fixture.root / "src/llama-model.cpp").read_text(), self.fixture.before)
        self.assertEqual(list((self.fixture.root / "src/models").iterdir()), [])

    def test_missing_or_changed_parent_abi_symbol_revision_and_preimage_fail_closed(self):
        original = copy.deepcopy(self.manifest)
        for mutation in ("parent", "weekly", "abi", "symbol", "revision", "preimage"):
            self.manifest = copy.deepcopy(original)
            if mutation == "parent":
                self.manifest["parentSourcePatch"]["sha256"] = "f" * 64
            elif mutation == "weekly":
                self.manifest["parentWeeklyTextPatch"]["sha256"] = "f" * 64
            elif mutation == "abi":
                self.manifest["beamABI"] = True
            elif mutation == "symbol":
                self.manifest["capabilitySymbol"] = "quenderin_weekly_text_runtime_abi"
            elif mutation == "revision":
                self.manifest["upstreamRevision"] = "latest"
            elif mutation == "preimage":
                self.manifest["files"][0]["beforeSha256"] = "f" * 64
            self.save()
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                prism.apply_source_patch(self.fixture.root)
            self.assertEqual((self.fixture.root / "src/llama-model.cpp").read_text(), self.fixture.before)
        self.manifest = original
        self.save()
        self.fixture.lock.pop("weeklyTextPatch")
        with self.assertRaisesRegex(ValueError, "Beam.*identity"):
            prism.apply_source_patch(self.fixture.root)

    def test_stamp_requires_separate_beam_header(self):
        f = self.fixture
        identity = prism.apply_source_patch(f.root)
        artifact = f.project / "beam.xcframework"
        headers = artifact / "macos/llama.framework/Headers"
        headers.mkdir(parents=True)
        (headers / "ggml.h").write_text("GGML_TYPE_PTQ1_0 GGML_TYPE_PQ2_0")
        header = headers / "llama.h"
        header.write_text("int quenderin_muse_spark_runtime_abi(void);\nint quenderin_weekly_text_runtime_abi(void);")
        with self.assertRaisesRegex(ValueError, "Beam capability"):
            prism.stamp(f.root, artifact)
        self.assertFalse((artifact / prism.STAMP).exists())
        header.write_text(header.read_text() + "\nint quenderin_beam_runtime_abi(void);")
        self.assertEqual(prism.stamp(f.root, artifact), identity)


if __name__ == "__main__":
    unittest.main()
