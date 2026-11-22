import Testing

@testable import DualControlCore

@Test func versionIsSet() {
    #expect(!DualControlCore.version.isEmpty)
}
