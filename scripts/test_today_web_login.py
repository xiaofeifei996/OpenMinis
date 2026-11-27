#!/usr/bin/env python3
"""Offline security wiring checks + compile/run the unchanged production policy.

Default: exit 77 when swiftc is absent (explicit runtime SKIP), 1 on failure.
--require-swift makes a missing compiler fail; --static-only runs only static checks.
On macOS with Xcode, also typecheck the real sheet for iOS 16 / Swift 6.
No live website, account, SMS, cookie store, chat, or network is used.
"""
import argparse
import hashlib
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "src/ios/Providers/TodayWebLoginPolicy.swift"
SHEET = ROOT / "src/ios/Views/Providers/TodayWebLoginSheet.swift"
FIXTURES = ROOT / "scripts/today-web-login-tests"
EXPECTED_TESTS = 63


class WiringTests(unittest.TestCase):
    def setUp(self):
        self.sheet = SHEET.read_text()
        self.policy = POLICY.read_text()

    def test_public_interface_and_ios16(self):
        self.assertRegex(self.sheet, r"@MainActor\s+struct TodayWebLoginSheet: View")
        self.assertIn("let onComplete: (String) -> Void", self.sheet)
        self.assertIn("@StateObject", self.sheet)
        self.assertNotIn("@Observable", self.sheet)
        self.assertNotIn(".onChange(of: scenePhase) { old", self.sheet)
        self.assertEqual(self.sheet.count("decisionHandler: @escaping @MainActor @Sendable"), 2)

    def test_private_store_and_no_native_credential_capture(self):
        self.assertEqual(self.sheet.count("WKWebsiteDataStore.nonPersistent()"), 1)
        self.assertIn("configuration.websiteDataStore = store", self.sheet)
        for forbidden in ["WKWebsiteDataStore.default", "document.cookie", "evaluateJavaScript",
                          "TextField(", "SecureField(", "HTTPCookieStorage", "URLSession",
                          "print(", "logger", "NSLog", "localizedDescription",
                          "UIApplication.shared.open", "SFSafariViewController"]:
            self.assertNotIn(forbidden, self.sheet)

    def test_navigation_action_response_and_popup_share_allowlist(self):
        self.assertEqual(self.sheet.count("TodayWebLoginNavigation.allows("), 2)
        self.assertIn("navigationAction.request.url, initialBlank: initialBlank", self.sheet)
        self.assertIn("navigationResponse.response.url, initialBlank: initialBlank", self.sheet)
        self.assertIn("navigationResponse.canShowMIMEType", self.sheet)
        self.assertIn("!navigationAction.shouldPerformDownload", self.sheet)
        self.assertIn("if !isBlank { initialBlank = false }", self.sheet)
        popup = self.sheet.split("if navigationAction.targetFrame == nil {", 1)[1].split("\n        }", 1)[0]
        self.assertLess(popup.index("decisionHandler(.cancel)"), popup.index("webView.load("))
        self.assertIn("if !isBlank", popup)
        creator = self.sheet.split("createWebViewWith configuration:", 1)[1]
        self.assertNotIn("WKWebView(", creator)
        self.assertRegex(creator, r"\n\s+nil\n")
        for literal in ['host == "todayai.cn" || host == "www.todayai.cn"',
                        'url.scheme?.lowercased() == "https"', 'url.user == nil',
                        'url.password == nil', 'url.absoluteString == "about:blank"']:
            self.assertIn(literal, self.policy)
        for forbidden in ["hasSuffix(", "hasPrefix(", ".contains(host)"]:
            self.assertNotIn(forbidden, self.policy)

    def test_all_capture_triggers_and_weak_observer_hop(self):
        self.assertIn("WKHTTPCookieStoreObserver", self.sheet)
        self.assertIn("dataStore.httpCookieStore.add(self)", self.sheet)
        observer = self.sheet.split("nonisolated func cookiesDidChange", 1)[1].split("\n    }", 1)[0]
        self.assertIn("Task { @MainActor [weak self] in self?.checkSession() }", observer)
        self.assertNotIn("checkSession(store:", observer)
        finish = self.sheet.split("didFinish navigation:", 1)[1].split("\n    }", 1)[0]
        self.assertIn("checkSession()", finish)
        self.assertIn("if phase == .active { model.checkSession() }", self.sheet)
        self.assertIn('Button("I\'ve finished signing in") { model.checkSession() }', self.sheet)

    def test_only_readonly_verification_and_no_result_heuristic(self):
        self.assertEqual(self.sheet.count("TodayProvider."), 1)
        self.assertIn("_ = try await TodayProvider.fetchModels(sessionCookie: header)", self.sheet)
        for forbidden in ["sendMessage(", "streamMessage(", ".isEmpty", "models.count", "models.first"]:
            self.assertNotIn(forbidden, self.sheet)
        self.assertGreaterEqual(self.sheet.count("await store.allCookies()"), 2)
        self.assertIn("TodayWebLoginCookie.header(from: latest) == header", self.sheet)
        self.assertIn("self?.attempt.isCurrent(ticket) == true", self.sheet)
        self.assertIn("try Task.checkCancellation()", self.sheet)
        self.assertIn("Task { @MainActor [weak self]", self.sheet)

    def test_cancel_finish_and_teardown(self):
        complete = self.sheet.split("private func complete(", 1)[1].split("\n    }", 1)[0]
        self.assertIn("attempt.finish(ticket)", complete)
        self.assertLess(complete.index("close()"), complete.index("callback?(header)"))
        close = self.sheet.split("func close() {", 1)[1].split("\n    }", 1)[0]
        for statement in ["closed = true", "attempt.close()", "checkTask?.cancel()",
                          "checkTask = nil", "completion = nil", "httpCookieStore.remove(self)",
                          "webView.stopLoading()", "webView.navigationDelegate = nil", "webView.uiDelegate = nil"]:
            self.assertIn(statement, close)
        self.assertNotIn("callback?(", close)
        self.assertIn(".onDisappear { model.close() }", self.sheet)
        self.assertIn("coordinator.close()", self.sheet)
        self.assertIn("[onComplete, dismiss]", self.sheet)
        self.assertIn('Button("Retry") { model.checkSession() }', self.sheet)
        self.assertIn('Button("Continue signing in") { model.continueLogin() }', self.sheet)

    def test_strict_cookie_boundary_is_in_production_helper(self):
        for literal in ['name == "__Secure-better-auth.session_token"',
                        'domain == "todayai.cn" || domain == ".todayai.cn"',
                        'isSecure, path == "/", !value.isEmpty',
                        '!value.contains("\\r")', '!value.contains("\\n")',
                        'expiresDate.map({ $0 > now }) ?? true', 'headers.count == 1']:
            self.assertIn(literal, self.policy)
        self.assertIn("expiresDate: cookie.expiresDate).header(now: now)", self.policy)
        self.assertIn("isSecure: cookie.isSecure", self.policy)
        self.assertNotRegex((FIXTURES / "main.swift").read_text(), r"(?:struct|enum) TodayWebLogin(?:Cookie|Navigation|Attempt)")


def run(command, timeout=180):
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    if result.stdout:
        print(result.stdout, end="", flush=True)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr, flush=True)
    if result.returncode:
        raise RuntimeError("command failed with exit " + str(result.returncode))
    return result.stdout


def ios_typecheck(compiler, required):
    xcrun = shutil.which("xcrun")
    if sys.platform != "darwin" or not xcrun:
        print("SKIP: iOS 16 sheet typecheck needs macOS + Xcode; no iOS compile claimed.", flush=True)
        return not required
    sdk = subprocess.run([xcrun, "--sdk", "iphonesimulator", "--show-sdk-path"],
                         capture_output=True, text=True, timeout=30)
    if sdk.returncode:
        print("SKIP: iOS simulator SDK unavailable; no iOS compile claimed.", flush=True)
        return not required
    print("Typechecking real sheet + policy for iOS 16 / Swift 6 (provider signature stub only)...", flush=True)
    run([compiler, "-typecheck", "-swift-version", "6", "-strict-concurrency=complete",
         "-sdk", sdk.stdout.strip(), "-target", platform.machine() + "-apple-ios16.0-simulator",
         str(POLICY), str(SHEET), str(FIXTURES / "TypecheckSupport.swift")])
    print("PASS: iOS 16 / Swift 6 sheet typecheck.", flush=True)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--static-only", action="store_true")
    parser.add_argument("--require-swift", action="store_true")
    parser.add_argument("--require-ios-typecheck", action="store_true")
    args = parser.parse_args()
    if args.static_only and (args.require_swift or args.require_ios_typecheck):
        parser.error("--static-only cannot be combined with required compile checks")
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(WiringTests))
    if not result.wasSuccessful():
        return 1
    print("PASS: static safety wiring checks (not a runtime/iOS build).", flush=True)
    if args.static_only:
        print("SKIP: Swift fixtures explicitly disabled by --static-only.", flush=True)
        return 0
    compiler = shutil.which("swiftc")
    if not compiler:
        print("SKIP: swiftc unavailable; 0 Swift fixtures executed. NOT a runtime PASS.", flush=True)
        return 1 if args.require_swift or args.require_ios_typecheck else 77
    original = POLICY.read_bytes()
    sheet = SHEET.read_bytes()
    print("Production policy SHA256: " + hashlib.sha256(original).hexdigest(), flush=True)
    try:
        run([compiler, "--version"], timeout=30)
        with tempfile.TemporaryDirectory(prefix="today-web-login-") as folder:
            binary = Path(folder) / "fixtures"
            # Compile original files directly. No extraction, concatenation,
            # regex rewriting, copied policy implementation, or live services.
            command = [compiler, "-swift-version", "6", "-strict-concurrency=complete",
                       "-parse-as-library", str(POLICY), str(FIXTURES / "main.swift"), "-o", str(binary)]
            if sys.platform == "darwin":
                command[1:1] = ["-target", platform.machine() + "-apple-macosx12.0"]
            run(command)
            output = run([str(binary)], timeout=30)
            summary = re.search(r"^TODAY_WEB_LOGIN_FIXTURES passed=(\d+) failed=(\d+)$", output, re.M)
            if not summary or tuple(map(int, summary.groups())) != (EXPECTED_TESTS, 0):
                raise RuntimeError("missing or incomplete Swift fixture summary")
        if not ios_typecheck(compiler, args.require_ios_typecheck):
            raise RuntimeError("required iOS typecheck unavailable")
        if POLICY.read_bytes() != original or SHEET.read_bytes() != sheet:
            raise RuntimeError("production source changed during test; rerun")
    except (OSError, subprocess.SubprocessError, RuntimeError) as error:
        print("FAIL: " + str(error), file=sys.stderr, flush=True)
        return 1
    print(f"PASS: {EXPECTED_TESTS} real production-policy Swift fixtures; no live network.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
