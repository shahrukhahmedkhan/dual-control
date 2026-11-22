/// The simple commands inside a shell string (`sh -c` argument or terminal input), found by a minimal POSIX-style
/// lexer. It does not expand anything; constructs it does not model clear `isConfident`.
struct ShellScript {
    /// One word after quote removal.
    struct Word {
        var text: String
        /// Contains an expansion (`$X`, glob, brace) whose value the lexer cannot know.
        var isDynamic: Bool
    }

    /// Words between separators (`;`, `&`, `|`, newline, parentheses), minus redirections.
    struct SimpleCommand {
        var words: [Word] = []
        var redirectsOutput = false
        /// The files its redirections name, in or out.
        var redirectTargets: [Word] = []
    }

    var commands: [SimpleCommand] = []
    /// False after command substitution, heredocs, ANSI-C quoting, unterminated quotes or similar.
    var isConfident = true

    init(parsing source: String) {
        var lexer = Lexer(chars: Array(source))
        lexer.run()
        self = lexer.script
    }

    private init() {}

    private struct Lexer {
        let chars: [Character]
        var i = 0
        var script = ShellScript()
        var current = SimpleCommand()
        var word = ""
        var inWord = false
        var quoted = false
        var dynamic = false
        var nextWordIsRedirectTarget = false

        func peek(_ offset: Int = 1) -> Character? {
            i + offset < chars.count ? chars[i + offset] : nil
        }

        mutating func append(_ c: Character) {
            word.append(c)
            inWord = true
        }

        mutating func endWord() {
            guard inWord else { return }
            if nextWordIsRedirectTarget {
                nextWordIsRedirectTarget = false
                current.redirectTargets.append(Word(text: word, isDynamic: dynamic))
            } else {
                // `{` alone is a keyword; inside a word it may be brace expansion.
                let braces = !quoted && word != "{" && word != "}" && word.contains("{")
                current.words.append(Word(text: word, isDynamic: dynamic || braces))
            }
            word = ""
            inWord = false
            quoted = false
            dynamic = false
        }

        mutating func endCommand() {
            endWord()
            if nextWordIsRedirectTarget {
                script.isConfident = false
                nextWordIsRedirectTarget = false
            }
            if !current.words.isEmpty || current.redirectsOutput {
                script.commands.append(current)
            }
            current = SimpleCommand()
        }

        /// Drops a pending `2` in `2>file`: it names a file descriptor, not an argument.
        mutating func dropFileDescriptorWord() {
            if inWord, !quoted, !dynamic, word.allSatisfy(\.isNumber) {
                word = ""
                inWord = false
            }
            endWord()
        }

        mutating func redirect(output: Bool) {
            dropFileDescriptorWord()
            if peek() == "(" {
                script.isConfident = false  // process substitution
                return
            }
            if !output, peek() == "<" {
                script.isConfident = false  // heredoc
                i += 1
                return
            }
            if output, peek() == ">" || peek() == "|" {
                i += 1
            }
            if peek() == "&" {
                i += 1
                if let next = peek(), next.isNumber || next == "-" {
                    i += 1  // duplicates a descriptor; no file involved
                    return
                }
            }
            if !output, peek() == ">" {
                i += 1  // `<>` opens read-write
                current.redirectsOutput = true
            }
            if output {
                current.redirectsOutput = true
            }
            nextWordIsRedirectTarget = true
        }

        mutating func run() {
            while i < chars.count {
                let c = chars[i]
                switch c {
                case " ", "\t":
                    endWord()
                case "&" where peek() == ">":
                    endWord()
                    i += 1
                    redirect(output: true)
                case "\n", ";", "&", "|", "(", ")":
                    endCommand()
                case ">":
                    redirect(output: true)
                case "<":
                    redirect(output: false)
                case "'":
                    inWord = true
                    quoted = true
                    i += 1
                    while i < chars.count, chars[i] != "'" {
                        word.append(chars[i])
                        i += 1
                    }
                    if i >= chars.count { script.isConfident = false }
                case "\"":
                    inWord = true
                    quoted = true
                    i += 1
                    while i < chars.count, chars[i] != "\"" {
                        let d = chars[i]
                        if d == "\\", let next = peek(), "$`\"\\\n".contains(next) {
                            word.append(next)
                            i += 1
                        } else if d == "$" {
                            if peek() == "(" { script.isConfident = false }
                            dynamic = true
                            word.append(d)
                        } else {
                            if d == "`" { script.isConfident = false }
                            word.append(d)
                        }
                        i += 1
                    }
                    if i >= chars.count { script.isConfident = false }
                case "\\":
                    if let next = peek() {
                        if next != "\n" { append(next) }
                        i += 1
                    }
                case "$":
                    if peek() == "(" || peek() == "'" { script.isConfident = false }
                    dynamic = true
                    append(c)
                case "`":
                    script.isConfident = false
                    append(c)
                case "#" where !inWord:
                    while i + 1 < chars.count, chars[i + 1] != "\n" { i += 1 }
                case "*", "?", "[":
                    dynamic = true
                    append(c)
                default:
                    append(c)
                }
                i += 1
            }
            endCommand()
        }
    }
}
