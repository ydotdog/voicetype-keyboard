"""Release packaging checks. Runtime regressions live in VoiceTypeTests and
in test_recording_bridge_runtime.py; avoid asserting exact Swift UI code shapes.
"""
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def plist(path):
    with (ROOT / path).open('rb') as stream:
        return plistlib.load(stream)


def test_app_and_extensions_share_versions_and_only_needed_background_mode():
    app = plist('VoiceType/Info.plist')
    keyboard = plist('VoiceTypeKeyboard/Info.plist')
    activity = plist('VoiceTypeLiveActivity/Info.plist')
    for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
        assert app[key] == keyboard[key] == activity[key]
    assert app['UIBackgroundModes'] == ['audio']
    assert app['NSSupportsLiveActivities'] is True
    assert 'microphone' in app['NSMicrophoneUsageDescription'].lower()
    assert not app.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads', False)


def test_keyboard_has_shared_container_and_correct_extension_permissions():
    app_group = plist('VoiceType/VoiceType.entitlements')['com.apple.security.application-groups']
    keyboard_group = plist('VoiceTypeKeyboard/VoiceTypeKeyboard.entitlements')['com.apple.security.application-groups']
    assert app_group == keyboard_group == ['group.com.kyleqi.voicetype']
    extension = plist('VoiceTypeKeyboard/Info.plist')['NSExtension']
    assert extension['NSExtensionPointIdentifier'] == 'com.apple.keyboard-service'
    assert extension['NSExtensionAttributes']['RequestsOpenAccess'] is True


def test_keyboard_does_not_bypass_extension_api_restrictions():
    source = (ROOT / 'VoiceTypeKeyboard/KeyboardViewController.swift').read_text()
    for forbidden in ('sharedApplication', 'NSClassFromString', 'unsafeBitCast', 'openURLThroughApplicationRuntime', 'openURLThroughResponderChain'):
        assert forbidden not in source
    assert 'advanceToNextInputMode' in source or 'handleInputModeList' in source


def test_local_storekit_catalog_matches_consumable_credit_products():
    catalog = json.loads((ROOT / 'StoreKit/Products.storekit').read_text())
    products = catalog['products']
    expected = {
        'com.kyleqi.voicetype.credits.small': '0.99',
        'com.kyleqi.voicetype.credits.medium': '4.99',
        'com.kyleqi.voicetype.credits.large': '19.99',
    }
    assert len(products) == len(expected)
    assert {p['productID']: p['displayPrice'] for p in products} == expected
    assert all(p['type'] == 'Consumable' for p in products)


def test_privacy_manifests_do_not_declare_tracking():
    for path in ('VoiceType/PrivacyInfo.xcprivacy', 'VoiceTypeKeyboard/PrivacyInfo.xcprivacy'):
        manifest = plist(path)
        assert manifest['NSPrivacyTracking'] is False
        for api in manifest.get('NSPrivacyAccessedAPITypes', []):
            assert api['NSPrivacyAccessedAPITypeReasons']
