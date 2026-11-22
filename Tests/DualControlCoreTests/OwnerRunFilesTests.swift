import Foundation
import Testing

@testable import DualControlCore

@Test(arguments: [
    ".vscode/tasks.json", ".vscode/launch.json", ".vscode/settings.json", "app/.VSCode/Tasks.json", "x.code-workspace",
    ".idea/runConfigurations/Run.xml", ".idea/workspace.xml", ".run/App.run.xml",
    "App.xcodeproj/project.pbxproj", "App.xcodeproj/xcshareddata/xcschemes/App.xcscheme",
    "W.xcworkspace/xcshareddata/xcschemes/W.xcscheme",
    "Makefile", "sub/GNUmakefile", "makefile", "rules.mk", "CMakeLists.txt", "cmake/tool.cmake", "CMakePresets.json",
    "package.json", "web/package.json", "Package.swift",
    ".envrc", ".mise.toml", "mise.toml", ".mise/config.toml", ".tool-versions",
    ".pre-commit-config.yaml",
    ".git/hooks/pre-commit", "sub/.git/hooks/post-checkout", ".githooks/pre-push", ".husky/pre-commit",
    ".husky/_/husky.sh",
])
func filesTheOwnersToolsRunAreRecognised(_ path: String) {
    #expect(OwnerRunFiles.kind(of: path) != nil, "\(path)")
}

@Test(arguments: [
    "README.md", "src/main.c", "Makefile.txt", "docs/package.json.md", ".vscode/extensions.json", ".git/config",
    "hooks/pre-commit", ".idea/misc.xml", "App.xcodeproj/other.pbxproj", "tasks.json", "x.cmake.txt", "",
])
func otherFilesAreNot(_ path: String) {
    #expect(OwnerRunFiles.kind(of: path) == nil, "\(path)")
}

@Test func theReportListsThemFirstWithAWarning() {
    var report = SessionReport.make(lines: [])
    report.ownerRunFiles = OwnerRunScan(
        folder: "/work/p",
        files: [
            OwnerRunFile(path: "Makefile", kind: "make", createdByAgent: false),
            OwnerRunFile(path: ".vscode/tasks.json", kind: "VS Code tasks", createdByAgent: true),
            OwnerRunFile(path: "a|b`[x](y)`.mk", kind: "make (included makefile)", createdByAgent: true),
        ],
        scanned: 120,
        incomplete: true
    )
    let markdown = report.markdown
    let section = try? #require(markdown.range(of: "## Files your tools run ⚠️"))
    let commands = markdown.range(of: "## Commands")
    #expect(section != nil && commands != nil && section!.lowerBound < commands!.lowerBound)
    #expect(markdown.contains("**3 changed file(s) in the session folder run code as you**"))
    #expect(markdown.contains("| .vscode/tasks.json | VS Code tasks | new, written by the agent |"))
    #expect(markdown.contains("| Makefile | make | changed during the session |"))
    // Names are the agent's: escaped, so they can't add table cells, code or links.
    #expect(markdown.contains("| a\\|b\\`\\[x\\]\\(y\\)\\`.mk |"))
    #expect(markdown.contains("The scan stopped after 120 entries"))
    // Sorted by path.
    #expect(report.ownerRunFiles?.files.map(\.path) == [".vscode/tasks.json", "Makefile", "a|b`[x](y)`.mk"])
}

@Test func noChangedFilesIsSaidPlainly() {
    var report = SessionReport.make(lines: [])
    report.ownerRunFiles = OwnerRunScan(folder: "/work/p", files: [], scanned: 7, incomplete: false)
    #expect(report.markdown.contains("## Files your tools run\n"))
    #expect(report.markdown.contains("changed in the session folder (7 entries checked)."))
    #expect(!SessionReport.make(lines: []).markdown.contains("Files your tools run"))
}
