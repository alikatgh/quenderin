"""Signed-export image checks with small Mach-O payloads; no native runtime or weights."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value
image = load('apple_image', HERE.parent / 'verify_diffusion_apple_runtime.py')
fixtures = load('apple_text_fixtures', HERE / 'test_prism_apple_runtime.py')


class ImageExportTests(unittest.TestCase):
    def setUp(self):
        scratch = os.environ.get('QUENDERIN_DIFFUSION_TEST_SCRATCH') or os.environ.get('RUNNER_TEMP')
        if not scratch: raise RuntimeError('Use registered session scratch or hosted RUNNER_TEMP')
        temp = tempfile.TemporaryDirectory(dir=scratch, prefix='apple-image-export-')
        self.addCleanup(temp.cleanup); self.root = Path(temp.name)
        (self.root / 'shared').mkdir()
        (self.root / 'shared/image-model-catalog.json').write_text('{"fixture":true}')

    def app(self, target='ios'):
        app = self.root / 'Quenderin.app'
        contents = app / 'Contents' if target == 'macos' else app
        contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Quenderin'}))
        binary = contents / 'Frameworks/QuenderinDiffusion.framework' / ('Versions/A/QuenderinDiffusion' if target == 'macos' else 'QuenderinDiffusion')
        binary.parent.mkdir(parents=True)
        binary.write_bytes(fixtures.fat(1, signed=True) if target == 'macos' else fixtures.thin('arm64', 2, signed=True))
        native = contents / 'Frameworks/QuenderinDiffusion.framework'
        metadata = {'CFBundleIdentifier':'org.quenderin.diffusion', 'CFBundlePackageType':'FMWK',
                    'CFBundleShortVersionString':'1.0.0', 'CFBundleVersion':'1'}
        (native / 'Info.plist').write_bytes(plistlib.dumps(metadata))
        executable = contents / ('MacOS/Quenderin' if target == 'macos' else 'Quenderin')
        executable.parent.mkdir(exist_ok=True)
        executable.write_bytes(fixtures.fat(1, executable=True) if target == 'macos' else fixtures.thin('arm64', 2, executable=True))
        stamp = {'revision':'pinned-image', 'abiVersion':1, 'slices':[{'platform':target,'payload':image.prism.macho_payload(binary), 'bundleMetadata':metadata}]}
        return app, contents, binary, stamp

    def tools(self, *args):
        if args[:3] == ('xcrun','otool','-L'): return '@rpath/QuenderinDiffusion.framework/QuenderinDiffusion'
        if args[:2] == ('codesign','-d'): return 'Authority=Apple Distribution\nTeamIdentifier=9M2B2P4KSA'
        return ''

    def test_signed_ios_and_universal_mac_export_match_sealed_payload(self):
        for target in ('ios','macos'):
            with self.subTest(target=target):
                # Each target has a distinct new app path; no original is replaced.
                original_root = self.root
                self.root = original_root / target; (self.root / 'shared').mkdir(parents=True)
                (self.root / 'shared/image-model-catalog.json').write_text('{"fixture":true}')
                app, _, _, stamp = self.app(target)
                with patch.object(image,'verify',return_value=stamp), patch.object(image.prism,'run',side_effect=self.tools):
                    image.embed_evidence(app,target,self.root)
                    result = image.verify_app(app,target,self.root,signed=True)
                    self.assertEqual(result['abiVersion'],1)
                self.root = original_root

    def test_signed_mac_export_accepts_only_framework_build_synced_to_app(self):
        app, contents, binary, stamp = self.app('macos')
        app_info_path = contents / 'Info.plist'
        app_info = plistlib.loads(app_info_path.read_bytes())
        app_info.update(CFBundleShortVersionString='0.5.0', CFBundleVersion='20')
        app_info_path.write_bytes(plistlib.dumps(app_info))
        framework_info_path = contents / 'Frameworks/QuenderinDiffusion.framework/Info.plist'
        source_metadata = stamp['slices'][0]['bundleMetadata']
        framework_info_path.write_bytes(plistlib.dumps(dict(source_metadata, CFBundleVersion='20')))
        with patch.object(image,'verify',return_value=stamp), patch.object(image.prism,'run',side_effect=self.tools) as tools:
            image.embed_evidence(app,'macos',self.root)
            with self.assertRaisesRegex(ValueError,'bundle identity/version'):
                image.framework_metadata(framework_info_path.parent)
            with self.assertRaisesRegex(ValueError,'bundle identity/version'):
                image.verify_app(app,'macos',self.root)
            result = image.verify_app(app,'macos',self.root,signed=True)
            self.assertEqual(result['architectures'],['arm64','x86_64'])
            tools.assert_any_call('codesign','--verify','--strict',str(framework_info_path.parent))
            for change in ({'CFBundleVersion':'19'}, {'CFBundleVersion':'21'}, {'CFBundleVersion':''},
                           {'CFBundleVersion':'20.0'}, {'CFBundleVersion':1}, {'CFBundleVersion':20},
                           {'CFBundleShortVersionString':1.0}, {'CFBundleVersion':'20','CFBundleShortVersionString':'0.5.0'},
                           {'CFBundleVersion':'20','CFBundleIdentifier':'wrong.image'},
                           {'CFBundleVersion':'20','CFBundlePackageType':'APPL'}):
                with self.subTest(metadata=change):
                    framework_info_path.write_bytes(plistlib.dumps(dict(source_metadata, **change)))
                    with self.assertRaisesRegex(ValueError,'bundle identity/version'):
                        image.verify_app(app,'macos',self.root,signed=True)
                    with self.assertRaisesRegex(ValueError,'bundle identity/version'):
                        image.framework_metadata(framework_info_path.parent)
            framework_info_path.write_bytes(plistlib.dumps(dict(source_metadata, CFBundleVersion='20')))
            binary.write_bytes(fixtures.fat(1,signed=True,code=b'tampered-image'))
            with self.assertRaisesRegex(ValueError,'payload'):
                image.verify_app(app,'macos',self.root,signed=True)

    def test_missing_and_stale_final_framework_are_rejected(self):
        app, _, binary, stamp = self.app()
        with patch.object(image,'verify',return_value=stamp):
            binary.write_bytes(fixtures.thin('arm64',2,code=b'stale-image'))
            with self.assertRaisesRegex(ValueError,'payload'): image.verify_app(app,'ios',self.root)
            binary.unlink()
            with self.assertRaises(FileNotFoundError): image.verify_app(app,'ios',self.root)

    def test_unlinked_final_framework_is_rejected(self):
        app, _, _, stamp = self.app()
        with patch.object(image,'verify',return_value=stamp), patch.object(image.prism,'run',return_value='@rpath/llama.framework/llama'):
            with self.assertRaisesRegex(ValueError,'does not link'): image.verify_app(app,'ios',self.root)

    def test_adhoc_signature_is_rejected(self):
        app, _, _, stamp = self.app()
        def adhoc(*args):
            return 'Signature=adhoc\nTeamIdentifier=9M2B2P4KSA' if args[:2] == ('codesign','-d') else self.tools(*args)
        with patch.object(image,'verify',return_value=stamp), patch.object(image.prism,'run',side_effect=adhoc):
            image.embed_evidence(app,'ios',self.root)
            with self.assertRaisesRegex(ValueError,'signature'): image.verify_app(app,'ios',self.root,signed=True)

    def test_signed_catalog_and_provenance_cannot_drift(self):
        app, contents, _, stamp = self.app()
        with patch.object(image,'verify',return_value=stamp), patch.object(image.prism,'run',side_effect=self.tools):
            image.embed_evidence(app,'ios',self.root)
            (contents / 'quenderin-image-model-catalog.json').write_text('{}')
            with self.assertRaisesRegex(ValueError,'catalog'): image.verify_app(app,'ios',self.root,signed=True)
            image.embed_evidence(app,'ios',self.root)
            (contents / 'quenderin-diffusion-release.json').write_text('{}')
            with self.assertRaisesRegex(ValueError,'provenance'): image.verify_app(app,'ios',self.root,signed=True)

    def test_framework_bundle_version_cannot_be_empty(self):
        app, contents, _, stamp = self.app()
        with patch.object(image,'verify',return_value=stamp):
            (contents / 'Frameworks/QuenderinDiffusion.framework/Info.plist').write_bytes(plistlib.dumps({}))
            with self.assertRaisesRegex(ValueError,'bundle identity/version'): image.verify_app(app,'ios',self.root)


if __name__ == '__main__': unittest.main()
