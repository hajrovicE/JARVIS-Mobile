"""Inspect an unsigned Xcode archive without credentials, signing or network IO."""
import argparse
import json
import os
from pathlib import Path
import plistlib

from policy import ReleaseError, validate_built_app


def inspect_archive(path, build_number, source_sha):
    root = Path(path).resolve()
    app = root / 'Products/Applications/JarvisMobile.app'
    validate_built_app(app, build_number)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    archive = plistlib.loads((root / 'Info.plist').read_bytes())
    if not isinstance(archive, dict):
        raise ReleaseError('Archive metadata must be a dictionary')
    properties = archive.get('ApplicationProperties', {})
    if not isinstance(properties, dict):
        raise ReleaseError('Archive application metadata must be a dictionary')
    if properties.get('ApplicationPath') != 'Applications/JarvisMobile.app':
        raise ReleaseError('Archive application path is unexpected')
    for key in ('CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString'):
        if properties.get(key) != info.get(key):
            raise ReleaseError('Archive metadata does not match built application')
    if info.get('DTPlatformName') != 'iphoneos':
        raise ReleaseError('Archive must contain an iPhone device application')
    required = [app / 'JarvisMobile', app / 'Frameworks/llama.framework/llama',
                app / 'PrivacyInfo.xcprivacy', root / 'dSYMs/JarvisMobile.app.dSYM/Contents/Resources/DWARF/JarvisMobile']
    if any(not p.is_file() or p.stat().st_size == 0 for p in required):
        raise ReleaseError('Archive is missing executable, native runtime, privacy manifest or debug symbols')
    if any(app.rglob('*.xctest')) or any(app.rglob('*.gguf')):
        raise ReleaseError('Test bundles or model fixtures must not ship in archive')
    privacy = plistlib.loads((app / 'PrivacyInfo.xcprivacy').read_bytes())
    if privacy.get('NSPrivacyTracking') is not False:
        raise ReleaseError('Privacy manifest tracking declaration is unexpected')
    for key in ('NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription'):
        if not isinstance(info.get(key), str) or not info[key].strip():
            raise ReleaseError('Native microphone/Speech usage description is missing')
    return {'source_sha': source_sha, 'bundle_id': info['CFBundleIdentifier'],
            'build_number': info['CFBundleVersion'], 'marketing_version': info['CFBundleShortVersionString'],
            'unsigned_archive_verified': True, 'debug_symbols_present': True,
            'installable_ipa': False, 'testflight_upload_attempted': False,
            'physical_device_acceptance': 'not_verified',
            'remaining': ['Apple signing credentials and provisioning', 'Physical iPhone Metal, live speech and thermal acceptance']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    try:
        result = inspect_archive(args.archive, os.environ.get('BUILD_NUMBER', ''), os.environ.get('GITHUB_SHA', 'local'))
        Path(args.output).write_text(json.dumps(result, indent=2) + '\n')
        print('Unsigned archive, native runtime and debug symbols verified; signing was not attempted.')
    except (OSError, ValueError, ReleaseError) as error:
        raise SystemExit('Archive inspection failed: ' + (str(error) if isinstance(error, ReleaseError) else type(error).__name__))
