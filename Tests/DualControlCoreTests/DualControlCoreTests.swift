import Foundation
import Testing

@testable import DualControlCore

@Test func versionIsSet() {
    #expect(!DualControlCore.version.isEmpty)
}

/// `status` reports `DualControlCore.version` and the app bundle reports the Xcode project's MARKETING_VERSION. Xcode
/// can't read the Swift constant, so this keeps the two the same.
@Test func appBundleVersionMatchesCoreVersion() throws {
    let project = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/DualControl.xcodeproj/project.pbxproj")
    let text = try String(contentsOf: project, encoding: .utf8)
    let versions = text.split(separator: "\n").compactMap { line -> String? in
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count == 3, parts[0] == "MARKETING_VERSION", parts[1] == "=" else { return nil }
        return String(parts[2].dropLast())
    }
    #expect(!versions.isEmpty)
    #expect(Set(versions) == [DualControlCore.version])
}
