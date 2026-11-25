"""Host the production badge inside a REAL SwiftUI List on macOS CI.

Only UIKit's background color is substituted for its AppKit equivalent. The
ObservedObject initializer, result reads, identity and badge body are the
production code, not a snapshot subscriber or a simulated render callback.
Vision checks a bitmap drawn by the mounted List, without accessibility permission.
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
    program = 'import AppKit\nimport SwiftUI\nimport Vision\n' + harness + badge + r'''
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

// CI does not enable the process-wide accessibility tree. Inspect pixels from
// the actual mounted NSHostingView instead, with Vision text recognition.
@MainActor func rendered(_ window: NSWindow) throws -> (String, Int, NSBitmapImageRep) {
    let host = window.contentView!
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1500, pixelsHigh: 720,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
    rep.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: rep)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.minimumTextHeight = 0
    try VNImageRequestHandler(cgImage: rep.cgImage!, options: [:]).perform([request])
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ").lowercased().filter { !$0.isWhitespace }
    let data = rep.bitmapData!
    var red = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        for x in stride(from: rep.pixelsWide - 300, to: rep.pixelsWide, by: 2) {
            let offset = y * rep.bytesPerRow + x * 4
            if data[offset] > 160 && data[offset + 1] < 150 && data[offset + 2] < 150 { red += 1 }
        }
    }
    return (text, red, rep)
}
@MainActor func save(_ rep: NSBitmapImageRep, name: String) throws {
    let directory = URL(fileURLWithPath: "build/speedtest-ui", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
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
@MainActor func expect(_ window: NSWindow, latency: Bool, failed: Bool = false, name: String) async throws {
    var last = ""
    for _ in 0..<60 {
        let (text, red, rep) = try rendered(window)
        last = "OCR=\(text), red=\(red)"
        if text.contains("fast"), text.contains("0.3") == latency, (red > 3) == failed {
            try save(rep, name: name)
            return
        }
        try save(rep, name: "last-failure")
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    fatalError("SwiftUI List did not render latency=\(latency), failed=\(failed): \(last)")
}
// This reads the rendered one-row List bitmap, never the state or an
// accessibility label. OCR may confuse the seconds glyph, so parse the number.
@MainActor func clockReading(_ window: NSWindow, name: String) async throws -> Double {
    let pattern = try NSRegularExpression(pattern: #"([0-9]+)[.,]([0-9])"#)
    for _ in 0..<60 {
        let (_, _, rep) = try rendered(window)
        // The 500pt one-row fixture samples sub-10-second readings. Crop its
        // right-aligned numeric text, excluding the separate hourglass glyph:
        // Vision otherwise sometimes reads the icon + 0.0s as "20.0s".
        let numeric = rep.cgImage!.cropping(to: CGRect(x: CGFloat(rep.pixelsWide - 125),
            y: 0, width: 100, height: CGFloat(rep.pixelsHigh)))!
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0
        try VNImageRequestHandler(cgImage: numeric, options: [:]).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = pattern.firstMatch(in: text, range: range),
           let numberRange = Range(match.range, in: text),
           let value = Double(text[numberRange].replacingOccurrences(of: ",", with: ".")) {
            try save(rep, name: name)
            return value
        }
        try save(rep, name: "clock-ocr-failure")
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    fatalError("No elapsed seconds found in mounted SwiftUI List bitmap")
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
        try await expect(window, latency: false, name: "unmeasured")
        let clockWindow = mount(optimizer, ids: ["fast"])
        let run = Task { @MainActor in
            await optimizer.speedTestAll(sessionId: nil, concurrency: 1, perEntryTimeout: 600, includeAllAccounts: true)
        }
        for _ in 0..<1000 {
            if optimizer.held["fast"] != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        assert(optimizer.held.count == 1)
        assert(optimizer.latencyState.entry(id: "pending").result.phase == .queued)
        let first = try await clockReading(clockWindow, name: "running-first")
        try await Task.sleep(nanoseconds: 400_000_000)
        let second = try await clockReading(clockWindow, name: "running-later")
        assert(second - first >= 0.2, "Mounted TimelineView pixels did not advance: \(first) -> \(second)")
        assert(optimizer.held["fast"] != nil && optimizer.speedTestStatus.running)
        let (_, _, queuedBitmap) = try rendered(window)
        try save(queuedBitmap, name: "running-and-queued")
        print("PASS: real mounted SwiftUI TimelineView bitmap elapsed advances while the production request is held: \(first)s -> \(second)s")
        optimizer.held.removeValue(forKey: "fast")!.resume()
        try await expect(clockWindow, latency: true, name: "clock-finished")
        let frozen = try await clockReading(clockWindow, name: "frozen-first")
        try await Task.sleep(nanoseconds: 450_000_000)
        let stillFrozen = try await clockReading(clockWindow, name: "frozen-later")
        assert(frozen == 0.3 && stillFrozen == frozen)
        assert(leaf.result.phase == .finished && optimizer.held["pending"] != nil)
        clockWindow.close()
        print("PASS: real mounted bitmap freezes the final first-token value while the next probe keeps running")
        try await expect(window, latency: true, name: "first-live")
        assert(optimizer.speedTestStatus.running && optimizer.held["pending"] != nil)
        assert(optimizer.latencyState.entry(id: "pending").result.seconds == nil)
        print("PASS: real SwiftUI List renders first production badge while another probe is held indefinitely")
        window.close()
        let reopened = mount(optimizer, ids: ["pending", "fast"])
        try await expect(reopened, latency: true, name: "reopened")
        assert(optimizer.latencyState.entry(id: "fast") === leaf && optimizer.speedTestStatus.running)
        print("PASS: reopened/reordered List retains entry identity and displays current badge during active run")
        optimizer.holdRequests = false
        optimizer.releaseHeld()
        await run.value
        reopened.close()
        let recovery = mount(optimizer, ids: ["fast"])
        optimizer.failures["fast"] = "network unavailable"
        await optimizer.speedTestInstance(instanceId: "A", sessionId: nil)
        try await expect(recovery, latency: false, failed: true, name: "failed")
        optimizer.failures.removeAll()
        await optimizer.speedTestInstance(instanceId: "A", sessionId: nil)
        try await expect(recovery, latency: true, name: "recovered")
        recovery.close()
        print("PASS: real mounted SwiftUI badge replaces stale success with soft failure and recovers")
    }
}
'''
    swift = tmp / 'SpeedTestSwiftUI.swift'
    binary = tmp / 'speedtest-swiftui'
    swift.write_text(program)
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                    str(swift), '-o', str(binary)], check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=90)
