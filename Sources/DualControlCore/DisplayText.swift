/// Renders untrusted text for the owner so that what they see is exactly what runs.
///
/// Control characters, invisible format characters (bidi overrides, zero-width), line separators and every space
/// other than U+0020 are shown as escapes; backslashes and quotes are escaped so escapes cannot be forged.
public enum DisplayText {
    /// An argument vector as one line: arguments separated by spaces, quoted when they are empty or contain a space
    /// or a quote.
    public static func argv(_ argv: [String]) -> String {
        argv.map { argument in
            let body = escaped(argument)
            let needsQuotes = argument.isEmpty || argument.contains(" ") || argument.contains("\"")
            return needsQuotes ? "\"\(body.replacingAll("\"", with: "\\\""))\"" : body
        }.joined(separator: " ")
    }

    /// `text` escaped and cut to at most `limit` characters, ending in `…` if cut. Escapes are never split.
    public static func summary(_ text: String, limit: Int) -> String {
        let units = text.unicodeScalars.map(escape)
        guard units.reduce(0, { $0 + $1.count }) > limit else { return units.joined() }
        var result = ""
        var length = 0
        for unit in units {
            guard length + unit.count <= limit - 1 else { break }
            result += unit
            length += unit.count
        }
        return result + "…"
    }

    /// `text` with every hard-to-see character escaped.
    public static func escaped(_ text: String) -> String {
        text.unicodeScalars.map(escape).joined()
    }

    static func escape(_ scalar: Unicode.Scalar) -> String {
        switch scalar {
        case "\\": return "\\\\"
        case "\n": return "\\n"
        case "\t": return "\\t"
        case "\r": return "\\r"
        case " ": return " "
        default: break
        }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator, .surrogate, .privateUse,
            .unassigned:
            return "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
        default:
            return String(scalar)
        }
    }
}

extension String {
    func replacingAll(_ target: String, with replacement: String) -> String {
        split(separator: target, omittingEmptySubsequences: false).joined(separator: replacement)
    }
}
