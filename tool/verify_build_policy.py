#!/usr/bin/env python3
"""Verify release inputs and optional built artifacts using only the stdlib.

This is a source-policy check, not evidence of a Flutter/native/hardware build.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import BadZipFile, ZipFile

ROOT = Path(__file__).resolve().parent.parent
ANDROID = '{http://schemas.android.com/apk/res/android}'
REQUIRED = {
    'flutter_riverpod', 'firebase_core', 'firebase_auth', 'firebase_database',
    'flutter_blue_plus', 'wifi_iot', 'permission_handler', 'shared_preferences',
    'http', 'file_picker', 'path', 'path_provider', 'just_audio', 'audio_session',
    'speech_to_text', 'flutter_tts', 'flutter_gemma', 'llamadart',
}


def check(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def declared_packages(pubspec: str, section: str) -> set[str]:
    match = re.search(rf'^{section}:\n(.*?)(?=^\S|\Z)', pubspec, re.M | re.S)
    check(match is not None, f'Missing {section} section in pubspec.yaml')
    return set(re.findall(r'^  ([a-zA-Z_][\w]*):', match.group(1), re.M))


def verify_source(resolved: bool) -> None:
    pubspec = (ROOT / 'pubspec.yaml').read_text()
    direct = declared_packages(pubspec, 'dependencies')
    dev = declared_packages(pubspec, 'dev_dependencies')
    check(REQUIRED <= direct, f'Required mobile capabilities missing: {sorted(REQUIRED - direct)}')
    check(not re.search(r'^  assets:', pubspec, re.M),
          'Photo/screenshot assets must not be in the runtime Flutter bundle')
    check((ROOT / 'assets/images/logo.png').is_file(), 'Launcher logo source is missing')
    check('image_path: "assets/images/logo.png"' in pubspec, 'Launcher logo configuration changed')
    check('llamadart_native_runtimes:\n        - llama_cpp' in pubspec,
          'GGUF must retain llama_cpp without duplicating Gemma\'s LiteRT runtime')
    check((ROOT / '.flutter-version').read_text().strip() == '3.47.6',
          'Review SDK/native compatibility before changing the pinned Flutter version')
    wrapper = ROOT / 'android/gradle/wrapper/gradle-wrapper.jar'
    check(hashlib.sha256(wrapper.read_bytes()).hexdigest()
          == '76805e32c009c0cf0dd5d206bddc9fb22ea42e84db904b764f3047de095493f3',
          'Gradle wrapper bootstrap does not match the official 9.1.0 checksum')
    wrapper_properties = (ROOT / 'android/gradle/wrapper/gradle-wrapper.properties').read_text()
    check('gradle-9.1.0-bin.zip' in wrapper_properties
          and 'distributionSha256Sum=a17ddd85a26b6a7f5ddb71ff8b05fc5104c0202c6e64782429790c933686c806'
          in wrapper_properties, 'Gradle 9.1.0 binary distribution must remain checksum-verified')
    settings = (ROOT / 'android/settings.gradle.kts').read_text()
    check('id("com.android.application") version "9.0.1"' in settings
          and 'id("org.jetbrains.kotlin.android") version "2.3.20"' in settings,
          'Android plugins must match the reviewed Flutter/Gradle upgrade')
    properties = (ROOT / 'android/gradle.properties').read_text()
    check('android.builtInKotlin=false' in properties and 'android.newDsl=false' in properties,
          'Keep AGP 9 legacy-plugin compatibility until all native plugins migrate')

    imports: set[str] = set()
    for folder in ('lib', 'test', 'tool'):
        for path in (ROOT / folder).rglob('*.dart'):
            contents = path.read_text()
            imports.update(re.findall(r'(?:import|export)\s+[\'\"]package:([\w]+)/', contents))
            if folder == 'lib':
                check(not re.search(r'[\'\"]assets/images/[^\'\"]+', contents),
                      f'Bundled photo reference remains: {path.relative_to(ROOT)}')
    check(imports <= direct | dev | {'iot'},
          f'Dart imports have undeclared dependencies: {sorted(imports - direct - dev - {"iot"})}')
    # All retained non-SDK dependencies have a live import. This catches unused
    # native plugins being reintroduced while preserving both local AI engines.
    check((direct - {'flutter'}) <= imports,
          f'Unused direct dependencies: {sorted(direct - {"flutter"} - imports)}')

    gradle = (ROOT / 'android/app/build.gradle.kts').read_text()
    check('compileSdk = 36' in gradle, 'Native plugins require Android compile SDK 36')
    check('signingConfig = signingConfigs.getByName("debug")' not in gradle,
          'Release must never fall back to debug signing')
    for required in ('signingConfig = signingConfigs.getByName("release")',
                     'dependsOn(validateReleaseSigning)', 'isMinifyEnabled = true',
                     'isShrinkResources = true', 'proguard-android-optimize.txt'):
        check(required in gradle, f'Android release protection is missing: {required}')

    manifest = ET.parse(ROOT / 'android/app/src/main/AndroidManifest.xml').getroot()
    permissions = {item.get(ANDROID + 'name') for item in manifest.findall('uses-permission')}
    check({'android.permission.INTERNET', 'android.permission.RECORD_AUDIO',
           'android.permission.BLUETOOTH_SCAN', 'android.permission.BLUETOOTH_CONNECT'} <= permissions,
          'Network, BLE or microphone permission missing')
    check(not permissions.intersection({'android.permission.READ_CONTACTS',
                                       'android.permission.MANAGE_EXTERNAL_STORAGE',
                                       'android.permission.ACCESS_BACKGROUND_LOCATION'}),
          'An unused sensitive Android permission has been added')
    application = manifest.find('application')
    check(application.get(ANDROID + 'allowBackup') == 'false', 'Private app data backup must be disabled')
    check(application.get(ANDROID + 'networkSecurityConfig') == '@xml/network_security_config',
          'ESP32/cloud network policy is not attached')
    actions = {item.get(ANDROID + 'name') for item in manifest.findall('queries/intent/action')}
    check({'android.speech.RecognitionService', 'android.intent.action.TTS_SERVICE'} <= actions,
          'Android speech/TTS service visibility is missing')
    network = ET.parse(ROOT / 'android/app/src/main/res/xml/network_security_config.xml').getroot()
    check(network.find('base-config').get('cleartextTrafficPermitted') == 'true',
          'Dynamic-IP local ESP32 HTTP control must remain supported')
    cloud_domains = {
        domain.text for config in network.findall('domain-config')
        if config.get('cleartextTrafficPermitted') == 'false'
        for domain in config.findall('domain')
    }
    check({'firebaseio.com', 'firebasedatabase.app', 'googleapis.com'} <= cloud_domains,
          'Firebase cloud domains must reject cleartext')
    ET.parse(ROOT / 'android/app/src/main/res/xml/data_extraction_rules.xml')

    with (ROOT / 'ios/Runner/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    ats = info['NSAppTransportSecurity']
    check(not ats.get('NSAllowsArbitraryLoads'), 'Global iOS ATS bypass must not be enabled')
    check(ats.get('NSAllowsLocalNetworking') is True, 'iOS local-network exception missing')
    expected_ranges = {'10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16'}
    check(set(ats['NSExceptionDomains']) == expected_ranges,
          'iOS HTTP exceptions must be limited to private/link-local IPv4 ranges')
    check(all(value.get('NSExceptionAllowsInsecureHTTPLoads') is True
              for value in ats['NSExceptionDomains'].values()), 'Local iOS HTTP exception is disabled')
    check(not {'NSCameraUsageDescription', 'NSPhotoLibraryUsageDescription',
               'NSContactsUsageDescription', 'NSBonjourServices'}.intersection(info),
          'Unused iOS camera/photo/contact/discovery permissions remain')

    for workflow in (ROOT / '.github/workflows').iterdir():
        if workflow.suffix not in {'.yml', '.yaml'}:
            continue
        text = workflow.read_text()
        check('contents: write' not in text and 'git push' not in text,
              f'Build workflow must not mutate/publish the repository: {workflow.name}')
        for reference in re.findall(r'uses:\s+([^\s#]+)', text):
            check(reference.startswith('./') or re.search(r'@[0-9a-f]{40}$', reference),
                  f'Action must be pinned to an immutable commit: {reference}')

    if resolved:
        lock = (ROOT / 'pubspec.lock').read_text()
        locked_direct: set[str] = set()
        for package, block in re.findall(r'^  (\w+):\n(.*?)(?=^  \w+:|^sdks:|\Z)', lock, re.M | re.S):
            if re.search(r'dependency:\s+[\'\"]?direct main', block):
                locked_direct.add(package)
        check(locked_direct == direct,
              'Lockfile is pending refresh; run bash tool/prepare_dependencies.sh --refresh')
        package_config = ROOT / '.dart_tool/package_config.json'
        check(package_config.is_file(), 'Run Flutter pub get to generate package_config.json')
        packages = {item['name'] for item in json.loads(package_config.read_text())['packages']}
        check(direct <= packages, 'Resolved package graph is missing a declared capability')
        registrant = ROOT / 'ios/Runner/GeneratedPluginRegistrant.m'
        check(registrant.is_file(), 'Flutter pub get must regenerate native plugin registrants')
        plugin_imports = set(re.findall(r'@import\s+(\w+)', registrant.read_text()))
        check(plugin_imports <= packages,
              f'Stale native plugin imports: {sorted(plugin_imports - packages)}')


def verify_artifact(path: Path) -> None:
    check(path.suffix in {'.aab', '.apk'}, 'Artifact must be an Android .aab or .apk')
    with ZipFile(path) as artifact:
        entries = artifact.infolist()
        forbidden = [item.filename for item in entries
                     if 'flutter_assets/' in item.filename
                     and ('assets/images/' in item.filename
                          or item.filename.endswith(('.gguf', '.task', '.safetensors')))]
        check(not forbidden, f'Unexpected bundled photos/model weights: {forbidden}')
        if path.suffix == '.aab':
            names = {item.filename.upper() for item in entries}
            check(any(name.startswith('META-INF/') and name.endswith('.SF') for name in names)
                  and any(name.startswith('META-INF/') and name.endswith(('.RSA', '.EC', '.DSA'))
                          for name in names), 'AAB signing metadata is missing')
            verifier = shutil.which('jarsigner')
            check(verifier is not None, 'Install JDK 17 to verify the AAB signature')
            result = subprocess.run([verifier, '-J-Duser.language=en', '-verify', str(path)],
                                    capture_output=True, text=True, check=True)
            check('jar verified.' in result.stdout, 'AAB cryptographic signature verification failed')
        else:
            verifier = shutil.which('apksigner')
            if verifier is None:
                sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
                candidates = list((Path(sdk) / 'build-tools').glob('*/apksigner')) if sdk else []
                candidates.sort(key=lambda item: tuple(int(n) for n in re.findall(r'\d+', item.parent.name)))
                verifier = str(candidates[-1]) if candidates else None
            check(verifier is not None, 'Install Android build tools to verify the APK signature')
            subprocess.run([verifier, 'verify', '--verbose', str(path)], check=True)
        print(f'{path.name}: verified signature; {path.stat().st_size:,} compressed bytes')
        for item in sorted(entries, key=lambda item: item.file_size, reverse=True)[:5]:
            print(f'  {item.file_size:>12,} uncompressed bytes  {item.filename}')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resolved', action='store_true', help='Also check the refreshed lock/plugin graph')
    parser.add_argument('--artifact', type=Path, help='Verify an actual signed APK/AAB and inspect its bundle')
    arguments = parser.parse_args()
    try:
        verify_source(arguments.resolved)
        if arguments.artifact:
            verify_artifact(arguments.artifact)
    except (ValueError, KeyError, OSError, BadZipFile, ET.ParseError,
            subprocess.CalledProcessError) as error:
        print(f'Build policy failed: {error}', file=sys.stderr)
        return 1
    print('Mobile source policy: OK' + ('; resolved dependency graph: OK' if arguments.resolved else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
