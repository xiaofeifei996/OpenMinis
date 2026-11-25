#!/usr/bin/env python3
"""Focused menu regressions: source wiring, native geometry, UIKit simulator pixels.

The simulator opens the production overlay programmatically. Gesture dependency
is checked in source; this does NOT claim a physical long-press/device test.
"""
from pathlib import Path
import argparse
import json
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
picker = (ROOT / 'src/ios/Views/Providers/UnifiedModelPicker.swift').read_text()
helper = picker[picker.index('// MARK: - Clear speed-test diagnostics menu'):]
buttons = picker[picker.index('    /// The manual speed-test toolbar button.'):picker.index('    /// [T-speedtest-unavailable]')]
catalog = json.loads((ROOT / 'src/ios/SpeedTest.xcstrings').read_text())
checks = {
    'global and API controls both receive the export callback':
        picker.count('export: exportSpeedTestDiagnostics) {') == 2,
    'speed-test buttons no longer mount the native context menu':
        'diagnosticsExportButton' not in picker and '.contextMenu' not in buttons,
    'only one tap handler, explicitly dependent on long-press failure':
        'tap.require(toFail: hold)' in helper and 'Button(action:' not in buttons + helper
        and 'minimumPressDuration = 0.5' in helper and 'hold.allowableMovement = 10' in helper,
    'hold only opens on began and never dispatches a speed test':
        'gesture.state == .began' in helper
        and 'parent.action()' not in helper.split('@objc func hold(', 1)[1].split('\n    }', 1)[0],
    'clear backdrop and opaque card, no system modal or blur mechanism':
        'backgroundColor = .clear' in helper and 'card.backgroundColor = .systemBackground' in helper
        and all(token not in helper for token in ['UIVisualEffectView', '.blur(', '.material',
                '.contextMenu', '.confirmationDialog', '.actionSheet', '.present(']),
    'outside tap, outside drag, escape and source teardown dismiss':
        'outside.addTarget(self, action: #selector(close)' in helper
        and '#selector(outsidePan(_:))' in helper and 'accessibilityPerformEscape()' in helper
        and 'coordinator.menu?.dismiss()' in helper,
    'safe-area layout clamps size and position and dismisses detached anchors':
        'bounds.inset(by: safeAreaInsets)' in helper and 'SpeedTestMenuLayout.frame(' in helper
        and 'anchor.window === window' in helper,
    'accessibility primary/export actions and modal menu focus':
        '.accessibilityAction { if !isDisabled { action() } }' in helper
        and '.accessibilityAction(named: Text(' in helper and 'accessibilityViewIsModal = true' in helper
        and 'notification: .screenChanged, argument: menu.card' in helper,
    'running only gates taps, not long-press diagnostics':
        '!parent.isDisabled' in helper and '.disabled(' not in buttons,
    'menu and accessibility export reuse the translated catalog key':
        helper.count('"Export speed-test diagnostics", table') == 2
        and catalog['strings']['Export speed-test diagnostics']['localizations']['zh-Hans']['stringUnit']['value'] == '导出测速诊断',
}
for name, passed in checks.items():
    print(('PASS' if passed else 'FAIL') + ': ' + name, flush=True)
assert all(checks.values())
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--static-only', action='store_true')
args = parser.parse_args()
if args.static_only:
    print('SKIP: native Swift geometry and UIKit simulator (not available on Linux)')
    raise SystemExit(0)


def run(*command, **kwargs):
    return subprocess.run(command, check=True, text=True, **kwargs)


geometry = helper[helper.index('private enum SpeedTestMenuLayout'):helper.index('/// No presentation controller')]
with tempfile.TemporaryDirectory(prefix='speedtest-menu-') as temp:
    temp = Path(temp)
    swift = temp / 'Geometry.swift'
    swift.write_text('import Foundation\nimport CoreGraphics\n' + geometry + '''
let safe = CGRect(x: 12, y: 60, width: 296, height: 520)
for x in [-100.0, 0, 160, 319, 800] {
    for y in [-100.0, 60, 300, 570, 900] {
        for size in [CGSize(width: 320, height: 56), CGSize(width: 500, height: 800)] {
            let frame = SpeedTestMenuLayout.frame(anchor: CGRect(x: x, y: y, width: 44, height: 44), available: safe, size: size)
            assert(safe.contains(frame))
        }
    }
}
let top = SpeedTestMenuLayout.frame(anchor: CGRect(x: 20, y: 60, width: 44, height: 44), available: safe, size: CGSize(width: 260, height: 60))
let bottom = SpeedTestMenuLayout.frame(anchor: CGRect(x: 270, y: 530, width: 44, height: 44), available: safe, size: CGSize(width: 260, height: 60))
assert(top.minY == 112 && bottom.maxY == 522)
print("PASS: 50 production geometry cases, safe-area clamping, above/below placement")
''')
    run('swiftc', str(swift), '-o', str(temp / 'geometry'), timeout=90)
    run(str(temp / 'geometry'), timeout=30)

    # A tiny, unsigned test app with the exact production helper, no app/native
    # dependencies or replacement menu implementation.
    program = 'import SwiftUI\nimport UIKit\n' + helper + r'''
@MainActor final class MenuTestDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.check(window) }
        return true
    }
    func check(_ window: UIWindow) {
        let base = window.rootViewController!.view!
        base.backgroundColor = .white
        for index in 0..<40 {
            let stripe = UIView(frame: CGRect(x: 0, y: CGFloat(index) * 24, width: window.bounds.width, height: 12))
            stripe.backgroundColor = index.isMultiple(of: 2) ? .red : .blue
            base.addSubview(stripe)
        }
        let anchor = UIView(frame: CGRect(x: 20, y: 80, width: 44, height: 44))
        base.addSubview(anchor)
        window.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }())
        func snapshot() -> UIImage {
            renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        }
        let before = snapshot()
        var exports = 0
        let overlay = SpeedTestDiagnosticsMenu.show(in: window, anchor: anchor) { exports += 1 }
        assert(overlay.backgroundColor == .clear)
        assert(overlay.accessibilityViewIsModal)
        func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
        assert(!descendants(overlay).contains { $0 is UIVisualEffectView })
        let card = descendants(overlay).compactMap { $0 as? UIButton }.first!
        assert(card.backgroundColor == .systemBackground)
        assert(window.bounds.inset(by: window.safeAreaInsets).contains(card.frame))
        let after = snapshot()
        // Compare actual UIKit hierarchy pixels, far below the card and shadow.
        let region = CGRect(x: 20, y: window.bounds.height - 220, width: window.bounds.width - 40, height: 120)
        let a = before.cgImage!.cropping(to: region)!.dataProvider!.data! as Data
        let b = after.cgImage!.cropping(to: region)!.dataProvider!.data! as Data
        assert(a == b, "Background pixels changed beneath clear overlay")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try! before.pngData()!.write(to: docs.appendingPathComponent("menu-before.png"))
        try! after.pngData()!.write(to: docs.appendingPathComponent("menu-open.png"))
        print("PASS: UIKit simulator overlay keeps background pixels identical; no visual-effect descendants")
        card.sendActions(for: .touchUpInside)
        assert(exports == 1 && overlay.superview == nil)
        let escape = SpeedTestDiagnosticsMenu.show(in: window, anchor: anchor) { exports += 1 }
        assert(escape.accessibilityPerformEscape() && escape.superview == nil && exports == 1)
        let outside = SpeedTestDiagnosticsMenu.show(in: window, anchor: anchor) { exports += 1 }
        let backdrop = outside.subviews.compactMap { $0 as? UIControl }.first!
        backdrop.sendActions(for: .touchUpInside)
        assert(outside.superview == nil && window.hitTest(CGPoint(x: 30, y: 700), with: nil) !== outside)
        print("PASS: UIKit export once, outside dismissal, accessibility escape and underlying hit-testing restored")
        print("NOT VERIFIED: physical long-press/tap arbitration, iOS 16 runtime, real-device scrolling and network")
        fflush(stdout)
        exit(0)
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(MenuTestDelegate.self))
'''
    app = temp / 'SpeedTestMenu.app'
    app.mkdir()
    bundle = 'com.openminis.speedtest-menu-regression'
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': bundle, 'CFBundleExecutable': 'SpeedTestMenu',
        'CFBundleName': 'SpeedTestMenu', 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
        'MinimumOSVersion': '16.0', 'UILaunchScreen': {},
        'UIDeviceFamily': [1, 2], 'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
    }))
    swift = temp / 'main.swift'
    swift.write_text(program)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    architecture = subprocess.check_output(['uname', '-m'], text=True).strip()
    run('xcrun', 'swiftc', '-swift-version', '5', '-sdk', sdk,
        '-target', architecture + '-apple-ios16.0-simulator', str(swift), '-o', str(app / 'SpeedTestMenu'), timeout=180)
    run('codesign', '--force', '--sign', '-', str(app), timeout=30)
    runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '-j'], text=True))['runtimes']
    runtime = next(r['identifier'] for r in reversed(runtimes) if r.get('isAvailable') and '.iOS-' in r['identifier'])
    device = subprocess.check_output(['xcrun', 'simctl', 'create', 'SpeedTestMenuRegression',
                                     'com.apple.CoreSimulator.SimDeviceType.iPhone-16', runtime], text=True).strip()
    try:
        run('xcrun', 'simctl', 'boot', device, timeout=60)
        run('xcrun', 'simctl', 'bootstatus', device, '-b', timeout=300)
        run('xcrun', 'simctl', 'install', device, str(app), timeout=90)
        run('xcrun', 'simctl', 'launch', '--console', '--terminate-running-process', device, bundle, timeout=120)
        container = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', device, bundle, 'data'], text=True).strip()
        evidence = ROOT / 'build/speedtest-ui'
        evidence.mkdir(parents=True, exist_ok=True)
        for name in ['menu-before.png', 'menu-open.png']:
            shutil.copyfile(Path(container) / 'Documents' / name, evidence / name)
    finally:
        subprocess.run(['xcrun', 'simctl', 'shutdown', device], check=False, timeout=60)
        subprocess.run(['xcrun', 'simctl', 'delete', device], check=False, timeout=60)
