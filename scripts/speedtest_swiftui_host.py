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

// Classify hue rather than absolute green brightness: antialiased red ink
// blended with white has green > 100 too, but is still red, not orange.
// Requiring chroma rejects gray labels/backgrounds; the hue gap makes the
// two assertions mutually exclusive without relaxing timeout verification.
func badgeInk(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (red: Bool, orange: Bool) {
    let chroma = Int(r) - Int(b)
    guard r > 160 && chroma > 60 else { return (false, false) }
    let warmth = Int(g) - Int(b)
    return (warmth * 100 < chroma * 35,
            warmth * 100 >= chroma * 40 && warmth * 100 < chroma * 85)
}
func verifyBadgeInk() {
    for background in [230, 255] {
        for alpha in 30...100 {
            func blend(_ value: Int) -> UInt8 {
                UInt8((value * alpha + background * (100 - alpha)) / 100)
            }
            let red = badgeInk(blend(255), blend(59), blend(48))
            let orange = badgeInk(blend(255), blend(149), blend(0))
            assert(red.red && !red.orange, "Antialiased red must never count as orange")
            assert(orange.orange && !orange.red, "Antialiased orange must never count as red")
        }
    }
    for gray in UInt8.min...UInt8.max {
        let ink = badgeInk(gray, gray, gray)
        assert(!ink.red && !ink.orange, "Gray must not count as status ink")
    }
    print("PASS: badge hue separates red/orange antialiasing on light backgrounds and rejects gray")
}
// CI does not enable the process-wide accessibility tree. Inspect pixels from
// the actual mounted NSHostingView instead, with Vision text recognition.
@MainActor func rendered(_ window: NSWindow) throws -> (String, Int, Int, NSBitmapImageRep) {
    let host = window.contentView!
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1500, pixelsHigh: 720,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
    rep.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: rep)
    // Vision misses small, light orange glyphs on white in otherwise correct
    // rendered timeout badges. Darken saturated ink ONLY in an OCR copy; the
    // original screenshot and raw red/orange pixel assertions stay untouched.
    let recognition = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide,
        pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: rep.bytesPerRow, bitsPerPixel: 32)!
    recognition.bitmapData!.update(from: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
    let ink = recognition.bitmapData!
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            let offset = y * rep.bytesPerRow + x * 4
            let gray = min(ink[offset], min(ink[offset + 1], ink[offset + 2]))
            ink[offset] = gray; ink[offset + 1] = gray; ink[offset + 2] = gray
        }
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.minimumTextHeight = 0
    try VNImageRequestHandler(cgImage: recognition.cgImage!, options: [:]).perform([request])
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ").lowercased().filter { !$0.isWhitespace }
    let data = rep.bitmapData!
    var red = 0
    var orange = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        for x in stride(from: rep.pixelsWide - 300, to: rep.pixelsWide, by: 2) {
            let offset = y * rep.bytesPerRow + x * 4
            let ink = badgeInk(data[offset], data[offset + 1], data[offset + 2])
            if ink.red { red += 1 }
            if ink.orange { orange += 1 }
        }
    }
    return (text, red, orange, rep)
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
@MainActor func expect(_ window: NSWindow, latency: Bool, failed: Bool = false,
                       timedOut: Bool = false, name: String) async throws {
    var last = ""
    for _ in 0..<60 {
        let (text, red, orange, rep) = try rendered(window)
        last = "OCR=\(text), red=\(red), orange=\(orange)"
        if text.contains("fast"), text.contains("0.3") == latency,
           text.contains("timedout") == timedOut, (red > 3) == failed,
           (orange > 3) == timedOut {
            try save(rep, name: name)
            return
        }
        try save(rep, name: "last-failure")
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    fatalError("SwiftUI List state=\(name) did not render latency=\(latency), failed=\(failed), timedOut=\(timedOut): \(last)")
}
@main struct SwiftUIRegression {
    @MainActor static func main() async throws {
        verifyBadgeInk()
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
        let run = Task { @MainActor in
            await optimizer.speedTestAll(sessionId: nil, perEntryTimeout: 600, includeAllAccounts: true)
        }
        for _ in 0..<100 {
            if optimizer.held.count == 2 { break }
            await Task.yield()
        }
        assert(optimizer.held.count == 2)
        optimizer.held.removeValue(forKey: "fast")!.resume()
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
        optimizer.failures["fast"] = "first-token timeout"
        await optimizer.speedTestInstance(instanceId: "A", sessionId: nil)
        try await expect(recovery, latency: false, timedOut: true, name: "timed-out-not-unavailable")
        optimizer.recordSuccessfulTextQuickTest(entry: optimizer.catalog[0])
        try await expect(recovery, latency: false, name: "text-verified-without-fake-ttft")
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
