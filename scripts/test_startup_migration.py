"""Compile the actual migration body with sandbox paths, without UIKit."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'src/ios/MinisApp.swift').read_text()
start = source.index('    private static func migrateSharedDirToAppGroup() {')
end = source.index('    /// Print the canonical AppGroup paths', start)
method = source[start:end].replace('private static func', 'static func', 1)
# Replace only OS path lookups; all migration branches and file operations are real.
method = method.replace('fm.urls(for: .libraryDirectory, in: .userDomainMask).first', 'Optional(testLibrary)')
lookup = 'fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.openminis.app")'
assert lookup in method
method = method.replace(lookup, 'testContainer')
assert 'testContainer!' not in method
registration = source[source.index('    private static func registerFileProviderDomain() {'):]
assert registration.index(') != nil else {') < registration.index('FileProviderBootHealth.shouldWithholdRegistration()')
program = r'''
import Foundation
let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let testLibrary = sandbox.appendingPathComponent("Library")
var testContainer: URL? = nil
struct Log { func info(_ message: String) {} }
let lifecycleLog = Log()
enum AIChatViewModel {
    static var root: URL {
        (testContainer ?? testLibrary.appendingPathComponent("Application Support/MinisAppGroupFallback"))
            .appendingPathComponent("MinisFileProvider")
    }
    static var minisSharedPersistentDir: URL { root.appendingPathComponent("shared") }
    static var minisMemoryPersistentDir: URL { root.appendingPathComponent("memory") }
    static var minisSkillsPersistentDir: URL { root.appendingPathComponent("skills") }
}
enum Harness {
''' + method + r'''
}
func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}
func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
defer { try? FileManager.default.removeItem(at: sandbox) }
for sub in ["shared", "memory", "skills"] {
    try write(testLibrary.appendingPathComponent("MinisChat/\(sub)/legacy.txt"), sub)
}
let collision = testLibrary.appendingPathComponent("MinisChat/shared/collision.txt")
try write(collision, "old")
try write(AIChatViewModel.minisSharedPersistentDir.appendingPathComponent("collision.txt"), "current")
Harness.migrateSharedDirToAppGroup()
for sub in ["shared", "memory", "skills"] {
    let value = try read(AIChatViewModel.root.appendingPathComponent("\(sub)/legacy.txt"))
    precondition(value == sub)
}
let old = try read(collision)
let current = try read(AIChatViewModel.minisSharedPersistentDir.appendingPathComponent("collision.txt"))
precondition(old == "old" && current == "current")
Harness.migrateSharedDirToAppGroup() // idempotent; no deletion of collisions
precondition(FileManager.default.fileExists(atPath: collision.path))
testContainer = sandbox.appendingPathComponent("AppGroup")
try write(testContainer!.appendingPathComponent("MinisShared/group.txt"), "group")
Harness.migrateSharedDirToAppGroup()
let migrated = try read(AIChatViewModel.minisSharedPersistentDir.appendingPathComponent("group.txt"))
precondition(migrated == "group")
print("Startup migration tests passed (nil group, group, collisions, repeat)")
'''
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / 'main.swift'
    path.write_text(program)
    binary = Path(tmp) / 'migration-test'
    subprocess.run(['swiftc', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
