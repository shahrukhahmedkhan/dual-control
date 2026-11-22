import Testing

@testable import DualControlCore

@Test(
    arguments: [
        (["ls"], "ls"),
        (["echo", "a b"], #"echo "a b""#),
        (["x", ""], #"x """#),
        (["a\nb\tc\r"], #"a\nb\tc\r"#),
        (["a\\b"], #"a\\b"#),
        ([#"say "hi""#], #""say \"hi\"""#),
        (["\u{1b}[31m"], #"\u{1B}[31m"#),
        (["\u{7f}\u{85}"], #"\u{7F}\u{85}"#),
        // Bidi overrides, zero-width and look-alike spaces would hide what really runs.
        (["\u{202E}txt.exe"], #"\u{202E}txt.exe"#),
        (["rm\u{200B}"], #"rm\u{200B}"#),
        (["a\u{00A0}b"], #"a\u{A0}b"#),
        (["a\u{2028}b"], #"a\u{2028}b"#),
        (["café", "日本"], "café 日本"),
    ]
)
func argvIsShownUnambiguously(_ argv: [String], _ expected: String) {
    #expect(DisplayText.argv(argv) == expected)
}

@Test func distinctArgvsLookDistinct() {
    let lookalikes: [[String]] = [["a b"], ["a", "b"], ["a\u{00A0}b"], [#"a\ b"#], ["a\\", "b"], ["a\n"], [#"a\n"#]]
    let shown = lookalikes.map(DisplayText.argv)
    #expect(Set(shown).count == lookalikes.count)
}

@Test func summariesAreEscapedAndTruncated() {
    #expect(DisplayText.summary("make\n", limit: 10) == #"make\n"#)
    #expect(DisplayText.summary(String(repeating: "x", count: 20), limit: 10) == "xxxxxxxxx…")
    #expect(DisplayText.summary("\u{1b}\u{1b}\u{1b}", limit: 10) == #"\u{1B}…"#)
}
