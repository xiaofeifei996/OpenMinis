"""Host the production badge inside a REAL SwiftUI List on macOS CI.

Only UIKit's background color is substituted for its AppKit equivalent. The
ObservedObject initializer, result reads, identity and accessibility are the
production code, not a snapshot subscriber or a simulated render callback.
This exercises SwiftUI mounting/invalidation, NOT iOS device pixels/scrolling.
"""
import subprocess


def run_swiftui_test(harness, picker, tmp):
    start = picker.index('    @MainActor\n    private struct LatencyBadgeCell: View')
    end = picker.index('    /// The manual speed-test toolbar button.', start)
    badge = picker[start:end].replace('private struct LatencyBadgeCell', 'struct LatencyBadgeCell')
    badge = badge.replace('UIColor.tertiarySystemFill', 'NSColor.controlBackgroundColor')
    harness = harness.replace('@MainActor final class ChatOptimizer {',
                              '@MainActor final class ChatOptimizer {\n    static let shared = ChatOptimizer()')
    program = 'import AppKit\nimport SwiftUI\n' + harness + badge + r'''
@MainActor struct MountedPicker: View {
    let optimizer: ChatOptimizer
    let ids: [String]
    var body: some View {
        List {
            ForEach(ids, id: \.self) { id in
                HStack {
                    Text(id)
                    Spacer()
                    LatencyBadgeCell(entryId: id, optimizer: optimizer).id(id)
                }
            }
        }.frame(width: 500, height: 240)
    }
}

// Query the hosting window's real accessibility tree, not the source model.
// Objective-C selectors also reach SwiftUI's private accessibility proxy nodes.
@MainActor func attribute(_ object: NSObject, _ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector) else { return nil }
    return object.perform(selector)?.takeUnretainedValue()
}
@MainActor func labels(_ object: Any, depth: Int = 0) -> [String: String] {
    guard depth < 40, let object = object as? NSObject else { return [:] }
    var result: [String: String] = [:]
    if let id = attribute(object, "accessibilityIdentifier") as? String,
       let label = attribute(object, "accessibilityLabel") as? String {
        result[id] = label
    }
    if let children = attribute(object, "accessibilityChildren") as? [Any] {
        for child in children {
            result.merge(labels(child, depth: depth + 1)) { _, new in new }
        }
    }
    return result
}
@MainActor func mount(_ optimizer: ChatOptimizer, ids: [String]) -> NSWindow {
    let host = NSHostingView(rootView: MountedPicker(optimizer: optimizer, ids: ids))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    return window
}
@MainActor func expect(_ window: NSWindow, id: String, label: String) async throws {
    for _ in 0..<150 {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        if labels(window)["latency-" + id] == label { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    fatalError("SwiftUI List did not render \(id)=\(label); actual accessibility tree: \(labels(window))")
}
@main struct SwiftUIRegression {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let optimizer = ChatOptimizer()
        optimizer.catalog = [ModelEntry(id: "fast", providerInstanceId: "A"),
                             ModelEntry(id: "pending", providerInstanceId: "B")]
        optimizer.holdRequests = true
        let leaf = optimizer.latencyState.entry(id: "fast")
        let window = mount(optimizer, ids: ["fast", "pending"])
        try await expect(window, id: "fast", label: "Latency unmeasured")
        let run = Task { @MainActor in
            await optimizer.speedTestAll(sessionId: nil, includeAllAccounts: true)
        }
        for _ in 0..<100 {
            if optimizer.held.count == 2 { break }
            await Task.yield()
        }
        assert(optimizer.held.count == 2)
        optimizer.held.removeValue(forKey: "fast")!.resume()
        try await expect(window, id: "fast", label: "0.3s")
        assert(optimizer.speedTestStatus.running && optimizer.held["pending"] != nil)
        try await expect(window, id: "pending", label: "Latency unmeasured")
        print("PASS: real SwiftUI List renders first production badge while another probe is held indefinitely")
        window.close()
        let reopened = mount(optimizer, ids: ["pending", "fast"])
        try await expect(reopened, id: "fast", label: "0.3s")
        assert(optimizer.latencyState.entry(id: "fast") === leaf && optimizer.speedTestStatus.running)
        print("PASS: reopened/reordered List retains entry identity and displays current badge during active run")
        optimizer.holdRequests = false
        optimizer.releaseHeld()
        await run.value
        optimizer.failures["fast"] = "network unavailable"
        await optimizer.speedTestInstance(instanceId: "A", sessionId: nil)
        try await expect(reopened, id: "fast", label: "Latency test failed")
        optimizer.failures.removeAll()
        await optimizer.speedTestInstance(instanceId: "A", sessionId: nil)
        try await expect(reopened, id: "fast", label: "0.3s")
        reopened.close()
        print("PASS: real mounted SwiftUI badge replaces stale success with soft failure and recovers")
    }
}
'''
    swift = tmp / 'SpeedTestSwiftUI.swift'
    binary = tmp / 'speedtest-swiftui'
    swift.write_text(program)
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                    str(swift), '-o', str(binary)], check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=30)
