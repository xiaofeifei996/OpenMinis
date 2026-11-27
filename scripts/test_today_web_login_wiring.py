#!/usr/bin/env python3
"""Static wiring checks for Today AI official-web login integration."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ADD = ROOT / "src/ios/Views/Providers/AddProviderView.swift"
DETAIL = ROOT / "src/ios/Views/Providers/ProviderInstanceDetailView.swift"
SHEET = ROOT / "src/ios/Views/Providers/TodayWebLoginSheet.swift"
POLICY = ROOT / "src/ios/Providers/TodayWebLoginPolicy.swift"
PBX = ROOT / "src/ios/Minis.xcodeproj/project.pbxproj"
WORKFLOW = ROOT / ".github/workflows/workbuddy-oauth-check.yml"
CATALOG = ROOT / "src/ios/Localizable.xcstrings"


class TodayWebLoginIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.add = ADD.read_text()
        cls.detail = DETAIL.read_text()
        cls.sheet = SHEET.read_text()
        cls.policy = POLICY.read_text()
        cls.pbx = PBX.read_text()
        cls.workflow = WORKFLOW.read_text()
        cls.catalog = json.loads(CATALOG.read_text())["strings"]

    def test_add_and_existing_instance_entry_points(self):
        self.assertIn('if selectedType == .today {\n                Section {\n                    Button {\n                        showTodayWebLogin = true', self.add)
        self.assertIn('if instance.providerType == .today {\n                Section {\n                    Button {\n                        showTodayWebLogin = true', self.detail)
        self.assertIn('TodayWebLoginSheet { cookie in', self.add)
        self.assertIn('TodayWebLoginSheet { cookie in', self.detail)
        self.assertIn('@State private var showTodayWebLogin = false', self.add)
        self.assertIn('@State private var showTodayWebLogin = false', self.detail)

    def test_new_login_saves_as_api_key_after_success(self):
        body = self.add.split('private func saveTodayLoginCookie', 1)[1].split('private func saveApiKeyInstance', 1)[0]
        self.assertIn('providerType: .today', body)
        self.assertIn('credentialType: .apiKey', body)
        self.assertIn('ProviderKeychainHelper.saveAPIKey(cookie, instanceId: instance.id)', body)
        self.assertIn('store.addInstance(instance)', body)
        self.assertNotIn('saveOAuthString', body)
        self.assertNotIn('ProviderCredential.oauth', body)
        self.assertIn('saveTodayLoginCookie(cookie)', self.add)

    def test_existing_instance_relogin_preserves_identity_and_refreshes(self):
        sheet = self.detail.split('.sheet(isPresented: $showTodayWebLogin)', 1)[1].split('.sheet(isPresented: $showManualTokenInput)', 1)[0]
        self.assertIn('instance.providerType == .today', sheet)
        self.assertIn('ProviderKeychainHelper.saveAPIKey(cookie, instanceId: instance.id)', sheet)
        self.assertIn('keyInputText = cookie', sheet)
        self.assertIn('Task { await store.refreshModels(for: instance) }', sheet)
        self.assertNotIn('store.addInstance', sheet)
        self.assertNotIn('saveOAuthString', sheet)

    def test_manual_cookie_fallback_remains_available(self):
        self.assertIn('SecureField(keyPlaceholder, text: $apiKeyInput)', self.add)
        self.assertIn('Text("Paste the __Secure-better-auth.session_token cookie from your signed-in todayai.cn session. It is stored securely in the iOS Keychain.")', self.add)
        self.assertIn('ProviderKeychainHelper.saveAPIKey(trimmedKey, instanceId: instance.id)', self.add)
        self.assertIn('ProviderKeychainHelper.saveAPIKey(trimmed, instanceId: instance.id)', self.detail)

    def test_today_credential_metadata_not_logged(self):
        # Generic API-key diagnostics retain their existing behavior, but all
        # hit/length/content metadata is gated away from the Today session cookie.
        self.assertIn('if instance.providerType != .today {\n                    AppLogger(category: "Provider").info("apiKeyTextField onAppear', self.detail)
        self.assertIn('if instance.providerType != .today {\n                        AppLogger(category: "Provider").info("apiKeyTextField onChange→SAVE', self.detail)
        self.assertIn('if instance.providerType != .today {\n                        AppLogger(category: "Provider").warning("apiKeyTextField onChange→DELETE', self.detail)
        self.assertNotIn('print(cookie)', self.add + self.detail + self.sheet)
        self.assertNotIn('print(apiKeyInput)', self.add)

    def test_sources_are_in_app_target_and_ci(self):
        for identifier in (
            'A77E00000000000000000001 /* TodayWebLoginSheet.swift in Sources */',
            'A77E00000000000000000002 /* TodayWebLoginPolicy.swift in Sources */',
            'A77E00000000000000000003 /* TodayWebLoginSheet.swift */',
            'A77E00000000000000000004 /* TodayWebLoginPolicy.swift */',
        ):
            self.assertIn(identifier, self.pbx)
        self.assertIn('src/ios/Views/Providers/TodayWebLoginSheet.swift \\\n', self.workflow)
        self.assertIn('src/ios/Providers/TodayWebLoginPolicy.swift \\\n', self.workflow)
        self.assertIn('python3 scripts/test_today_web_login.py --require-swift --require-ios-typecheck', self.workflow)
        self.assertIn('python3 scripts/test_today_web_login_wiring.py', self.workflow)

    def test_all_new_ui_strings_have_simplified_chinese(self):
        for key in (
            'Sign in with Today AI',
            'Sign in on the official Today AI page. Enter your phone number and verification code there; Minis does not collect them.',
            'Today AI Website Login',
            'The Today AI page could not be loaded. Please try again.',
            'Reload page',
            "We couldn't verify the session. Check your connection or sign in again.",
            'Retry',
            'Continue signing in',
            'Reading Today AI session status…',
            'After signing in, tap “I\'ve finished signing in” to check the session.',
            "I've finished signing in",
        ):
            with self.subTest(key=key):
                self.assertIn(key, self.catalog)
                self.assertIn('zh-Hans', self.catalog[key].get('localizations', {}))


if __name__ == '__main__':
    unittest.main(verbosity=2)
