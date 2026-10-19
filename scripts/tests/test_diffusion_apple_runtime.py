"""Signed-export image checks with small Mach-O payloads; no native runtime or weights."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
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


def metadata(target):
    return {'CFBundleIdentifier':'org.quenderin.diffusion', 'CFBundlePackageType':'FMWK',
            'CFBundleShortVersionString':'1.0.0', 'CFBundleVersion':'1',
            'CFBundleExecutable':'QuenderinDiffusion', 'CFBundleName':'QuenderinDiffusion',
            'CFBundleInfoDictionaryVersion':'6.0',
            'CFBundleSupportedPlatforms':['MacOSX' if target == 'macos' else 'iPhoneOS'],
            'LSMinimumSystemVersion' if target == 'macos' else 'MinimumOSVersion':'13.3' if target == 'macos' else '16.4'}


def change_macho_target(data, minimum, arch=None, platform=None):
    data = bytearray(data)
    offsets = [0]
    if data[:4] == b'\xca\xfe\xba\xbe':
        offsets = [struct.unpack_from('>I', data, 8 + index * 20 + 8)[0]
                   for index in range(struct.unpack_from('>I', data, 4)[0])]
    for base in offsets:
        cpu = struct.unpack_from('<I', data, base + 4)[0]
        if arch is not None and cpu != {'arm64':0x0100000C, 'x86_64':0x01000007}[arch]: continue
        cursor = base + 32
        for _ in range(struct.unpack_from('<I', data, base + 16)[0]):
            command, size = struct.unpack_from('<II', data, cursor)
            if command == 0x32:
                struct.pack_into('<I', data, cursor + 12, minimum)
                if platform is not None: struct.pack_into('<I', data, cursor + 8, platform)
            cursor += size
    return bytes(data)


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
        minimum_key = 'LSMinimumSystemVersion' if target == 'macos' else 'MinimumOSVersion'
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Quenderin',
            minimum_key:'13.3' if target == 'macos' else '16.4'}))
        binary = contents / 'Frameworks/QuenderinDiffusion.framework' / ('Versions/A/QuenderinDiffusion' if target == 'macos' else 'QuenderinDiffusion')
        binary.parent.mkdir(parents=True)
        binary.write_bytes(fixtures.fat(1, signed=True) if target == 'macos' else fixtures.thin('arm64', 2, signed=True))
        native = contents / 'Frameworks/QuenderinDiffusion.framework'
        bundle_metadata = metadata(target)
        (native / 'Info.plist').write_bytes(plistlib.dumps(bundle_metadata))
        executable = contents / ('MacOS/Quenderin' if target == 'macos' else 'Quenderin')
        executable.parent.mkdir(exist_ok=True)
        executable.write_bytes(fixtures.fat(1, executable=True) if target == 'macos' else fixtures.thin('arm64', 2, executable=True))
        stamp = {'revision':'pinned-image', 'abiVersion':1, 'slices':[{'platform':target,'payload':image.prism.macho_payload(binary), 'bundleMetadata':bundle_metadata}]}
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
                image.framework_metadata(framework_info_path.parent,'macos',stamp['slices'][0]['payload'])
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
                        image.framework_metadata(framework_info_path.parent,'macos',stamp['slices'][0]['payload'])
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

    def test_framework_deployment_metadata_is_required_and_matches_every_macho_slice(self):
        for target in ('ios','macos'):
            with self.subTest(target=target):
                directory = self.root / target; directory.mkdir()
                info_path = directory / 'Info.plist'
                valid = metadata(target)
                minimum_key = 'LSMinimumSystemVersion' if target == 'macos' else 'MinimumOSVersion'
                binary = directory / 'QuenderinDiffusion'
                original = fixtures.fat(1) if target == 'macos' else fixtures.thin('arm64',2)
                binary.write_bytes(original)
                payload = image.prism.macho_payload(binary)
                info_path.write_bytes(plistlib.dumps(valid))
                self.assertEqual(image.framework_metadata(directory,target,payload),valid)
                for value in (None, '', 16.4, 16, True, [], '16', '16.4beta', ' 16.4', '16.4.0.0',
                              '0.0', '65536.0', '16.256', '16.4.256', '15.0', '14.0'):
                    with self.subTest(minimum=value):
                        changed = dict(valid)
                        if value is None: changed.pop(minimum_key)
                        else: changed[minimum_key] = value
                        info_path.write_bytes(plistlib.dumps(changed))
                        with self.assertRaisesRegex(ValueError,'deployment minimum'):
                            image.framework_metadata(directory,target,payload)
                for supported in (None, [], '', ['iPhoneSimulator'], ['MacOSX','iPhoneOS'],
                                  ['iPhoneOS','iPhoneOS'], ['iPhoneOS' if target == 'macos' else 'MacOSX']):
                    with self.subTest(supported=supported):
                        changed = dict(valid)
                        if supported is None: changed.pop('CFBundleSupportedPlatforms')
                        else: changed['CFBundleSupportedPlatforms'] = supported
                        info_path.write_bytes(plistlib.dumps(changed))
                        with self.assertRaisesRegex(ValueError,'supported platforms'):
                            image.framework_metadata(directory,target,payload)
                info_path.write_bytes(plistlib.dumps(valid))
                for wrong_platform in (1 if target == 'ios' else 2, 7, 6):
                    binary.write_bytes(change_macho_target(original,image.deployment_version(valid[minimum_key]),
                                                          arch='arm64',platform=wrong_platform))
                    with self.assertRaisesRegex(ValueError,'compiled target'):
                        image.framework_metadata(directory,target,image.prism.macho_payload(binary))
                binary.write_bytes(change_macho_target(original,14 << 16,arch='arm64'))
                with self.assertRaisesRegex(ValueError,'compiled target'):
                    image.framework_metadata(directory,target,image.prism.macho_payload(binary))
                # A matching plist/binary cannot silently change the pinned builder target.
                changed = dict(valid); changed[minimum_key] = '14.0'
                info_path.write_bytes(plistlib.dumps(changed))
                binary.write_bytes(change_macho_target(original,14 << 16))
                with self.assertRaisesRegex(ValueError,'compiled target'):
                    image.framework_metadata(directory,target,image.prism.macho_payload(binary))
                with self.assertRaisesRegex(ValueError,'Unexpected image framework platform'):
                    image.framework_metadata(directory,'tvos',payload)

    def test_source_seal_and_signed_export_reject_missing_deployment_metadata(self):
        app, contents, binary, stamp = self.app()
        native = binary.parent
        info_path = native / 'Info.plist'
        info = plistlib.loads(info_path.read_bytes()); info.pop('MinimumOSVersion')
        info_path.write_bytes(plistlib.dumps(info))
        with patch.object(image,'verify',return_value=stamp), patch.object(image.prism,'run',side_effect=self.tools):
            image.embed_evidence(app,'ios',self.root)
            with self.assertRaisesRegex(ValueError,'deployment minimum'):
                image.verify_app(app,'ios',self.root,signed=True)
        framework = self.root / 'QuenderinDiffusion.xcframework'
        directory = framework / 'ios-arm64/QuenderinDiffusion.framework'
        shutil.copytree(native,directory)
        (directory / 'Headers').mkdir(); (directory / 'Headers/quenderin_diffusion.h').write_text('fixture')
        (directory / 'Modules').mkdir(); (directory / 'Modules/module.modulemap').write_text('fixture')
        (framework / 'Info.plist').write_bytes(plistlib.dumps({'AvailableLibraries':[{
            'LibraryIdentifier':'ios-arm64','LibraryPath':'QuenderinDiffusion.framework','SupportedPlatform':'ios'}]}))
        with patch.object(image.subprocess,'run'),patch.object(image.subprocess,'check_output',return_value=''):
            with self.assertRaisesRegex(ValueError,'deployment minimum'):
                image.description(framework)

    def test_app_minimum_matches_its_binary_and_supports_the_framework(self):
        for target in ('ios','macos'):
            original_root = self.root
            self.root = original_root / target; (self.root / 'shared').mkdir(parents=True)
            app, contents, _, stamp = self.app(target)
            info_path = contents / 'Info.plist'
            valid = plistlib.loads(info_path.read_bytes())
            key = 'LSMinimumSystemVersion' if target == 'macos' else 'MinimumOSVersion'
            executable = contents / ('MacOS/Quenderin' if target == 'macos' else 'Quenderin')
            original = executable.read_bytes()
            with patch.object(image,'verify',return_value=stamp),patch.object(image.prism,'run',side_effect=self.tools):
                for minimum in (None, '', '1.0', '26.0'):
                    with self.subTest(target=target,minimum=minimum):
                        changed = dict(valid)
                        if minimum is None: changed.pop(key)
                        else: changed[key] = minimum
                        info_path.write_bytes(plistlib.dumps(changed))
                        with self.assertRaisesRegex(ValueError,'minimum'):
                            image.verify_app(app,target,self.root)
                changed = dict(valid); changed[key] = '1.0'
                info_path.write_bytes(plistlib.dumps(changed))
                executable.write_bytes(change_macho_target(original,1 << 16))
                with self.assertRaisesRegex(ValueError,'minimum OS'):
                    image.verify_app(app,target,self.root)
                # Raising the app's actual minimum remains compatible with its framework.
                changed[key] = '26.0'; info_path.write_bytes(plistlib.dumps(changed))
                executable.write_bytes(change_macho_target(original,26 << 16))
                image.verify_app(app,target,self.root)
            self.root = original_root

    def test_cmake_template_generates_deployment_and_platform_metadata(self):
        producer = image.ROOT / 'native/diffusion'
        for system, sdk, target, minimum in (('iOS','iphoneos','ios','16.4'),('Darwin','macosx','macos','13.3')):
            script = self.root / (target + '.cmake')
            output = self.root / (target + '.plist')
            script.write_text(f'''set(CMAKE_SYSTEM_NAME "{system}")
set(CMAKE_OSX_SYSROOT "{sdk}")
set(CMAKE_OSX_DEPLOYMENT_TARGET "{minimum}")
include("{producer / 'AppleFrameworkMetadata.cmake'}")
set(MACOSX_FRAMEWORK_NAME QuenderinDiffusion)
set(MACOSX_FRAMEWORK_IDENTIFIER org.quenderin.diffusion)
set(MACOSX_FRAMEWORK_BUNDLE_VERSION 1)
set(MACOSX_FRAMEWORK_SHORT_VERSION_STRING 1.0.0)
configure_file("{producer / 'Info.plist.in'}" "{output}")
''')
            subprocess.run(['cmake','-P',str(script)],check=True,capture_output=True,text=True)
            generated = plistlib.loads(output.read_bytes())
            expected = metadata(target)
            self.assertEqual({key:generated[key] for key in expected},expected)
        for system, sdk, minimum in (('tvOS','appletvos','16.4'),('iOS','iphonesimulator','16.4'),
                                     ('iOS','iphoneos',''),('Darwin','macosx','13.3beta')):
            with self.subTest(system=system,sdk=sdk,minimum=minimum):
                script = self.root / 'invalid.cmake'
                script.write_text(f'''set(CMAKE_SYSTEM_NAME "{system}")
set(CMAKE_OSX_SYSROOT "{sdk}")
set(CMAKE_OSX_DEPLOYMENT_TARGET "{minimum}")
include("{producer / 'AppleFrameworkMetadata.cmake'}")
''')
                result = subprocess.run(['cmake','-P',str(script)],capture_output=True,text=True)
                self.assertNotEqual(result.returncode,0,result.stdout)


if __name__ == '__main__': unittest.main()
