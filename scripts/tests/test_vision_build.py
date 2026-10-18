"""Vision resource sealing failure tests; synthetic bytes, no native builds."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_vision_runtime as vision

class VisionHostTests(unittest.TestCase):
    def test_linux_armv7_packaging_host_is_recognized(self):
        with patch.object(vision.platform, 'system', return_value='Linux'), patch.object(vision.platform, 'machine', return_value='armv7l'):
            self.assertEqual(vision.host(), ('linux', 'armv7l'))

class VisionSealTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vision-seal-fixture-'); self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.executable = self.directory / 'quenderin-vision-cli'; self.executable.write_bytes(b'unsigned fixture bytes')
        self.notice = self.directory / 'THIRD_PARTY_NOTICES.txt'; self.notice.write_text('fixture license')
        self.payload = {'arm64': {'platform': 1, 'minimumOS': 0, 'sha256': 'payload-fixture'}}
        self.stamp = dict(platform='mac', arch='arm64', source=vision.runtime.provenance(), bytes=self.executable.stat().st_size,
            sha256=vision.sha(self.executable), visionModelsSha256=vision.sha(vision.ROOT/'shared/vision-models.json'), noticesSha256=vision.sha(self.notice), machoPayload=self.payload)
        self.save()
        for owner, name, value in ((vision, 'host', ('mac', 'arm64')), (vision, 'probe', {}), (vision, 'dependencies', None), (vision.apple_runtime, 'macho_payload', self.payload)):
            obj = patch.object(owner, name, return_value=value); obj.start(); self.addCleanup(obj.stop)
    def save(self): (self.directory/vision.STAMP).write_text(json.dumps(self.stamp))
    def test_unsigned_and_packaged_identity(self):
        vision.verify(self.directory); vision.verify(self.directory, packaged=True)
        vision.probe.assert_called(); vision.dependencies.assert_called()
    def test_signature_only_mutation_requires_packaged_mode_and_same_payload(self):
        self.executable.write_bytes(b'resigned fixture bytes with a changed signature')
        with self.assertRaisesRegex(ValueError, 'whole-file'): vision.verify(self.directory)
        vision.verify(self.directory, packaged=True)
        vision.apple_runtime.macho_payload.return_value = {'arm64': {'platform': 1, 'minimumOS': 0, 'sha256': 'different-code'}}
        with self.assertRaisesRegex(ValueError, 'code or architecture'): vision.verify(self.directory, packaged=True)
    def test_other_architecture_and_source_patch_are_rejected(self):
        self.stamp['source']['visionPatchSha256'] = '0'*64; self.save()
        with self.assertRaises(ValueError): vision.verify(self.directory)
    def test_extra_file_and_modified_notice_are_rejected(self):
        extra = self.directory/'unexpected.so'; extra.write_bytes(b'wrong engine')
        with self.assertRaisesRegex(ValueError, 'unexpected'): vision.verify(self.directory)
        extra.unlink()
        self.notice.write_text('changed license')
        with self.assertRaisesRegex(ValueError, 'notices'): vision.verify(self.directory)
    def test_descriptor_change_is_rejected(self):
        self.stamp['visionModelsSha256'] = '0'*64; self.save()
        with self.assertRaises(ValueError): vision.verify(self.directory)

if __name__ == '__main__': unittest.main()
