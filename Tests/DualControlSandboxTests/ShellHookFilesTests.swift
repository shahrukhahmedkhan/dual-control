#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation
    import Testing

    @testable import DualControlSandbox

    private final class Folder {
        let root: String

        init() throws {
            var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
            let made = try #require(mkdtemp(&template).map { String(cString: $0) })
            root = try #require(RealPath.resolve(made))
        }

        func file(_ path: String) throws {
            let full = root + "/" + path
            try FileManager.default.createDirectory(
                atPath: (full as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            #expect(FileManager.default.createFile(atPath: full, contents: Data()))
        }

        deinit {
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    @Test func hookFilesInTheSessionFolderAreListed() throws {
        let folder = try Folder()
        for path in [
            ".envrc", "README.md", "app/.tool-versions", "app/src/.nvmrc", "app/src/deep/.envrc",
            "node_modules/x/.nvmrc", ".git/.envrc", "docs/notes.md",
        ] {
            try folder.file(path)
        }
        try FileManager.default.createDirectory(atPath: folder.root + "/.venv", withIntermediateDirectories: true)
        // A symlink counts by its name and is not followed.
        try FileManager.default.createSymbolicLink(atPath: folder.root + "/app/.env", withDestinationPath: "/etc/hosts")
        try FileManager.default.createSymbolicLink(atPath: folder.root + "/loop", withDestinationPath: folder.root)

        let found = ShellHookFiles.find(in: folder.root)
        #expect(found.files == [".envrc", ".venv", "app/.env", "app/.tool-versions", "app/src/.nvmrc"])
        #expect(!found.incomplete)
    }

    @Test func aHugeFolderStopsTheScanAndSaysSo() throws {
        let folder = try Folder()
        for index in 0..<30 { try folder.file("f\(index)") }
        try folder.file(".envrc")
        let found = ShellHookFiles.find(in: folder.root, limit: 10)
        #expect(found.incomplete)
    }

    @Test func aMissingFolderHasNoHookFiles() {
        let found = ShellHookFiles.find(in: "/tmp/dc-test-no-such-folder-\(UUID().uuidString)")
        #expect(found.files.isEmpty)
    }
#endif
