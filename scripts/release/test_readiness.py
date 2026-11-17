import plistlib
from pathlib import Path
import tempfile
import unittest
from readiness import inspect_archive
from policy import ReleaseError


class ReadinessTests(unittest.TestCase):
    def fixture(self, root):
        app = root / 'Products/Applications/JarvisMobile.app'
        files = ['JarvisMobile', 'Frameworks/llama.framework/llama']
        for name in files:
            file = app / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b'synthetic binary; structure-only test')
        info = {'CFBundleIdentifier': 'com.jarvis.mobile', 'CFBundleVersion': '7',
                'CFBundleShortVersionString': '0.3.0', 'DTPlatformName': 'iphoneos',
                'NSMicrophoneUsageDescription': 'Türkçe mikrofon', 'NSSpeechRecognitionUsageDescription': 'Türkçe konuşma'}
        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
        (app / 'PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps({'NSPrivacyTracking': False}))
        (root / 'Info.plist').write_bytes(plistlib.dumps({'ApplicationProperties': {
            **{k: info[k] for k in ('CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString')},
            'ApplicationPath': 'Applications/JarvisMobile.app'}}))
        symbols = root / 'dSYMs/JarvisMobile.app.dSYM/Contents/Resources/DWARF/JarvisMobile'
        symbols.parent.mkdir(parents=True)
        symbols.write_bytes(b'synthetic symbols')
        return app, symbols

    def test_readiness_never_claims_signed_or_installed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            result = inspect_archive(root, '7', 'source')
            self.assertTrue(result['unsigned_archive_verified'])
            self.assertFalse(result['installable_ipa'])
            self.assertFalse(result['testflight_upload_attempted'])
            self.assertEqual(result['physical_device_acceptance'], 'not_verified')

    def test_missing_symbols_and_mismatched_archive_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app, symbols = self.fixture(root)
            symbols.unlink()
            with self.assertRaises(ReleaseError): inspect_archive(root, '7', 'source')
            symbols.write_bytes(b'synthetic symbols')
            (root / 'Info.plist').write_bytes(plistlib.dumps({'ApplicationProperties': {}}))
            with self.assertRaises(ReleaseError): inspect_archive(root, '7', 'source')

    def test_model_fixture_is_not_accepted_as_delivery_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app, _ = self.fixture(root)
            (app / 'model.gguf').write_bytes(b'fixture')
            with self.assertRaises(ReleaseError): inspect_archive(root, '7', 'source')
