#!/usr/bin/env python3
"""Static Today integration checks; no Swift toolchain or live account required.

Protocol fixtures and executable Swift coverage live in test_today_protocol.py.
These checks deliberately do not claim to typecheck Swift or test the service.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "src/ios"
WORKFLOW = ROOT / ".github/workflows/workbuddy-oauth-check.yml"
WARNING = (
    "Messages are sent to your Today AI account's shared main chat and may affect "
    "the website's conversation and context. Text only: images and agent tools "
    "are not supported. Canceling only stops local waiting and does not guarantee "
    "that upstream generation or billing stops."
)
COOKIE_HELP = (
    "Paste the __Secure-better-auth.session_token cookie from your signed-in "
    "todayai.cn session. It is stored securely in the iOS Keychain."
)
LOCALIZED_KEYS = [
    "Session Cookie", "Use a Today AI session cookie",
    "Sign in with a Today AI web session cookie — unofficial, use at your own risk",
    "Today AI Shared Chat Warning", WARNING, COOKIE_HELP,
]
NONCODE = re.compile(
    r'//[^\n]*|/\*[\s\S]*?\*/|#*"""[\s\S]*?"""#*|#*"(?:\\.|[^"\\])*"#*'
)


def read(relative):
    return (IOS / relative).read_text()


def case_body(source, case="today"):
    match = re.search(r"\bcase\s+\." + case + r"\s*:", source)
    if not match:
        raise AssertionError("missing case ." + case)
    tail = source[match.end():]
    end = re.search(r"\b(?:case|default)\b", tail)
    return tail[:end.start()] if end else tail


def switches(source):
    """Yield direct labels, ignoring comments, strings and nested switch labels.

    A source-level regression guard, not a replacement for Swift exhaustiveness
    checking. Looking for several known provider cases avoids unrelated enums.
    """
    masked = NONCODE.sub(lambda m: re.sub(r"[^\n]", " ", m.group()), source)
    for match in re.finditer(r"\bswitch\b[^{}]*\{", masked):
        depth, labels, has_default = 1, set(), False
        for token in re.finditer(r"[{}]|\bcase\b|\bdefault\b", masked[match.end():]):
            value = token.group()
            offset = match.end() + token.start()
            if value == "{":
                depth += 1
            elif value == "}":
                depth -= 1
                if depth == 0:
                    yield masked.count("\n", 0, match.start()) + 1, labels, has_default
                    break
            elif depth == 1 and value == "default":
                has_default = True
            elif depth == 1 and value == "case":
                colon = masked.find(":", offset)
                labels.update(re.findall(r"\.(\w+)", masked[offset:colon]))


class TodayWiringTests(unittest.TestCase):
    def test_source_is_native_text_provider(self):
        source = read("Providers/TodayProvider.swift")
        self.assertRegex(source, r"final class TodayProvider\s*:\s*LLMProvider\s*\{")
        self.assertNotRegex(source, r"(?:class|struct|extension) TodayProvider[^\n{]*AgentProvider")

    def test_factory_uses_cookie_and_dedicated_protocol(self):
        source = read("Providers/LLMProviderFactory.swift")
        branch = case_body(source)
        self.assertIn("makeTodayProvider(instance: instance, model: entry.model)", branch)
        self.assertNotIn("OpenAIProvider(", branch)
        builder = source.split("static func makeTodayProvider", 1)[1].split("\n    }", 1)[0]
        self.assertIn("ProviderKeychainHelper.loadAPIKey(instanceId: instance.id)", builder)
        self.assertIn("TodayProvider(sessionCookie: cookie, model: model)", builder)

    def test_models_are_dynamic_with_no_fabricated_fallback(self):
        types = read("Providers/ProviderTypes.swift")
        models = types.split("var builtInModels:", 1)[1].split("var pickerSubtitle:", 1)[0]
        branch = case_body(models)
        self.assertIn("return []", branch)
        self.assertNotIn("LLMModel(", branch)
        modality = types.split("var defaultModality:", 1)[1]
        self.assertRegex(modality, r"case[^:\n]*\.today[^:\n]*:\s*return \.textOnly")
        discovery = types.split("var oauthSupportsModelDiscovery:", 1)[1].split("var builtInModels:", 1)[0]
        self.assertIn("return false", case_body(discovery))

    def test_model_refresh_requires_cookie_not_oauth(self):
        store = read("Providers/ProviderConfigStore.swift")
        cookie_branch = store.split("case (.today, .apiKey):", 1)[1].split("case (.today, .oauth):", 1)[0]
        self.assertIn("modelFetchAPIKey(for: instance)", cookie_branch)
        self.assertIn("TodayProvider.fetchModels(sessionCookie: cookie)", cookie_branch)
        oauth = store.split("case (.today, .oauth):", 1)[1].split("case (.unsupported, _):", 1)[0]
        self.assertIn("throw ModelRefreshError.noCredential", oauth)
        self.assertNotIn("builtInModels", oauth)
        fallback = store.split("static func fetchModelsWithFallback(", 1)[1]
        direct = fallback.split("var warnings:", 1)[0]
        self.assertIn("if instance.providerType == .today", direct)
        self.assertIn("fetchModelsForInstance(instance, forceRefresh: forceRefresh)", direct)
        self.assertIn('source: "api"', direct)
        self.assertNotIn("ModelsDevAPI.", direct)

    def test_cookie_only_configuration(self):
        add = read("Views/Providers/AddProviderView.swift")
        credentials = add.split("private func availableCredentials(", 1)[1]
        self.assertIn("return [.apiKey]", case_body(credentials))
        for relative in ["Views/Providers/AddProviderView.swift", "Views/Providers/ProviderInstanceDetailView.swift"]:
            source = read(relative)
            with self.subTest(file=relative):
                self.assertIn('case .today: return "__Secure-better-auth.session_token=..."', source)
                self.assertIn("SecureField(", source)
                self.assertIn(".textContentType(.oneTimeCode)", source)
        self.assertIn("selectedType != .antigravity && selectedType != .today", add)
        detail = read("Views/Providers/ProviderInstanceDetailView.swift")
        self.assertIn("if instance.providerType != .today {\n                customBaseURLSection(instance)", detail)

    def test_quota_descriptor_has_independent_today_kind(self):
        source = read("Providers/Quota/QuotaAdapters.swift")
        kinds = source.split("enum ProviderKind:", 1)[1].split("}", 1)[0]
        self.assertRegex(kinds, r"\btoday\b")
        detector = source.split("switch d.providerKind", 1)[1].split("static func vendor(forHost", 1)[0]
        self.assertRegex(detector, r"case[^:]+\.today[^:]*:\s*return \.unknown")

    def test_today_credential_help_precedes_api_key_wildcard(self):
        source = read("Views/Providers/AddProviderView.swift")
        help_body = source.split("private func credentialDescription(", 1)[1].split("@ViewBuilder", 1)[0]
        self.assertEqual(help_body.count("case (.today, .apiKey):"), 1)
        self.assertEqual(help_body.count("case (.today, .oauth):"), 1)
        self.assertLess(help_body.index("case (.today, .apiKey):"), help_body.index("case (_, .apiKey):"))
        cookie = help_body.split("case (.today, .apiKey):", 1)[1].split("case ", 1)[0]
        self.assertIn(COOKIE_HELP, cookie)

    def test_shared_main_chat_and_cancellation_warning_is_visible(self):
        for relative in ["Views/Providers/AddProviderView.swift", "Views/Providers/ProviderInstanceDetailView.swift"]:
            source = read(relative)
            with self.subTest(file=relative):
                self.assertIn('Label(AppLocalized("' + WARNING + '")', source)
                self.assertIn('systemImage: "exclamationmark.triangle.fill"', source)
                self.assertIn('Text("Today AI Shared Chat Warning")', source)
                self.assertIn(COOKIE_HELP, source)

    def test_english_keys_have_source_and_chinese_translations(self):
        catalog = json.loads((IOS / "Localizable.xcstrings").read_text())
        self.assertEqual(catalog["sourceLanguage"], "en")
        for key in LOCALIZED_KEYS:
            with self.subTest(key=key[:65]):
                locales = catalog["strings"][key]["localizations"]
                self.assertEqual(locales["en"]["stringUnit"]["value"], key)
                self.assertTrue(locales["zh-Hans"]["stringUnit"]["value"])

    def test_xcode_registration_in_app_sources_and_provider_group(self):
        project = (IOS / "Minis.xcodeproj/project.pbxproj").read_text()
        ref = re.search(r'(\w+) /\* TodayProvider.swift \*/ = \{isa = PBXFileReference;[^\n]+path = TodayProvider.swift;', project)
        self.assertIsNotNone(ref)
        build = re.search(r'(\w+) /\* TodayProvider.swift in Sources \*/ = \{isa = PBXBuildFile; fileRef = (\w+)', project)
        self.assertIsNotNone(build)
        self.assertEqual(build.group(2), ref.group(1))
        group = project.split("E52000030 /* Providers */ = {", 1)[1].split("\n\t\t};", 1)[0]
        self.assertIn(ref.group(1) + " /* TodayProvider.swift */", group)
        sources = project.split("E51000041 /* Sources */ = {", 1)[1].split("\n\t\t};", 1)[0]
        self.assertIn(build.group(1) + " /* TodayProvider.swift in Sources */", sources)
        for object_id in [ref.group(1), build.group(1)]:
            self.assertEqual(len(re.findall(r"^\s*" + object_id + r" /\*[^\n]+\*/ =", project, re.M)), 1)

    def test_ci_runs_swift_parse_and_both_regressions(self):
        workflow = WORKFLOW.read_text()
        self.assertIn("src/ios/Providers/TodayProvider.swift \\\n", workflow)
        self.assertIn('swiftc -frontend -parse "$file"', workflow)
        self.assertIn("python3 scripts/test_today_provider.py", workflow)
        self.assertIn("python3 scripts/test_today_protocol.py --require-swift", workflow)

    def test_voice_factory_explicitly_excludes_today(self):
        source = read("Providers/Voice/VoiceProviderFactory.swift")
        labels = r"case[^:]+\.today[^:]+:\s*return "
        self.assertRegex(source, labels + "false")
        self.assertRegex(source, labels + "nil")

    def test_exhaustive_provider_switches_include_today(self):
        checked, missing = 0, []
        # Application Swift only; independent standalone test fixtures define
        # their own reduced ProviderType enums and are intentionally excluded.
        for path in IOS.rglob("*.swift"):
            if "MinisTests" in path.parts:
                continue
            source = path.read_text()
            if not all("." + case in source for case in ["openAI", "anthropic", "gemini"]):
                continue
            for line, labels, has_default in switches(source):
                if {"openAI", "anthropic", "gemini"}.issubset(labels):
                    checked += 1
                    if not has_default and "today" not in labels:
                        missing.append(str(path.relative_to(ROOT)) + ":" + str(line))
        self.assertGreaterEqual(checked, 20)
        self.assertEqual(missing, [], "ProviderType switches missing .today: " + ", ".join(missing))
        print("\nChecked", checked, "provider-shaped switches for Today coverage")

    def test_switch_guard_ignores_nested_defaults_and_string_content(self):
        sample = '''switch type {
        case .openAI, .anthropic, .gemini:
            let text = "case .today: { default: }"
            switch other { default: break }
        case .unsupported: break
        }'''
        results = list(switches(sample))
        self.assertIn((1, {"openAI", "anthropic", "gemini", "unsupported"}, False), results)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--static-only", action="store_true", help="Accepted for consistency; all checks are static.")
    _, remaining = parser.parse_known_args()
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)
