"""Experimental integrations retain exact immutable artifacts and explicit validation limits."""
import hashlib
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def read(path):
    return json.loads((ROOT / path).read_text())


class ExperimentalModelSupportTests(unittest.TestCase):
    def test_complete_artifact_sets_have_whole_model_memory_floors(self):
        for path in ("shared/beam-artifacts.json", "shared/hy-memory-artifacts.json"):
            with self.subTest(path=path):
                manifest = read(path)
                artifacts = manifest["artifacts"]
                self.assertIs(manifest["complete"], True)
                self.assertRegex(manifest["revision"], r"^[0-9a-f]{40}$")
                self.assertEqual(len(artifacts), manifest["shardCount"])
                self.assertEqual(len({item["filename"] for item in artifacts}), len(artifacts))
                self.assertEqual(manifest["entryPoint"], artifacts[0]["filename"])
                self.assertEqual(sum(item["downloadBytes"] for item in artifacts), manifest["totalDownloadBytes"])
                self.assertGreater(manifest["minimumMemoryBytes"], manifest["totalDownloadBytes"])
                for index, item in enumerate(artifacts, 1):
                    self.assertRegex(item["sha256"], r"^[0-9a-f]{64}$")
                    self.assertIs(type(item["downloadBytes"]), int)
                    self.assertGreater(item["downloadBytes"], 0)
                    self.assertEqual(item["url"], f'https://huggingface.co/{manifest["repository"]}/resolve/'
                                     f'{manifest["revision"]}/{item["filename"]}')
                    if manifest["shardCount"] > 1:
                        suffix = re.search(r"-(\d{5})-of-(\d{5})\.gguf$", item["filename"])
                        self.assertIsNotNone(suffix)
                        self.assertEqual(tuple(map(int, suffix.groups())), (index, len(artifacts)))

    def test_beam_metadata_shard_cannot_be_mistaken_for_the_model(self):
        manifest = read("shared/beam-artifacts.json")
        self.assertEqual(manifest["shardCount"], 4)
        self.assertEqual(manifest["artifacts"][0]["downloadBytes"], 5954020)
        self.assertEqual(manifest["totalDownloadBytes"], 133885310500)
        self.assertGreater(manifest["totalDownloadBytes"], manifest["artifacts"][0]["downloadBytes"] * 1000)

    def test_support_records_are_bound_and_only_complete_beam_is_in_normal_catalog(self):
        support = read("shared/experimental-model-support.json")
        catalog = read("shared/model-catalog.json")
        catalog_ids = {model["id"] for model in catalog["models"]}
        for model in support["models"]:
            with self.subTest(model=model["modelId"]):
                if model["modelId"].startswith("beam-"):
                    self.assertIs(model["appAvailable"], True)
                    self.assertIn(model["modelId"], catalog_ids)
                    entry = next(item for item in catalog["models"] if item["id"] == model["modelId"])
                    self.assertEqual(len(entry["artifacts"]), 4)
                    self.assertEqual(sum(item["downloadBytes"] for item in entry["artifacts"]), 133885310500)
                    self.assertEqual(model["validation"]["modelInference"], "not-run")
                else:
                    self.assertNotIn(model["modelId"], catalog_ids)
                self.assertTrue(model["status"].startswith("experimental-"))
                self.assertGreater(len(model["blockers"]), 0)
                artifact = model["artifactManifest"]
                self.assertEqual(hashlib.sha256((ROOT / artifact["path"]).read_bytes()).hexdigest(), artifact["sha256"])
                self.assertEqual(read(artifact["path"])["modelId"], model["modelId"])

    def test_beam_uses_its_own_patch_and_hy_requires_reviewed_memory_proposals(self):
        support = read("shared/experimental-model-support.json")
        beam, hy = support["models"]
        self.assertEqual(beam["runtime"]["requiredPatch"], read("shared/prism-runtime.json")["beamPatch"])
        self.assertEqual(beam["runtime"]["capabilitySymbol"], "quenderin_beam_runtime_abi")
        self.assertEqual(beam["chat"]["reasoningEffortTokenValue"], 8)
        self.assertEqual(hy["kind"], "memory-writer")
        workflow = hy["workflow"]
        self.assertIs(workflow["automaticPersistence"], False)
        self.assertIs(workflow["requiresExplicitApprovalBeforePersistence"], True)
        self.assertIs(workflow["rejectMalformedOrExtraFields"], True)
        self.assertIs(workflow["responseSchema"]["additionalProperties"], False)
        self.assertEqual(workflow["responseSchema"]["required"], ["memories"])
        self.assertEqual(hy["chat"]["reasoningEffort"], "no_think")


if __name__ == "__main__":
    unittest.main()
