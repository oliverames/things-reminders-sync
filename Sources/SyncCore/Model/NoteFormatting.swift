import Foundation

/// Converts notes between the two apps' display conventions (see "Field fidelity" in docs/SPEC.md).
///
/// - Things notes are Markdown, and a link the user saved shows as a bare URL on its own line.
/// - Reminders notes are plain text, and a saved link is a separate rich-link field.
public enum NoteFormatting {
    /// Splits a trailing link line off Things notes: the last non-empty line, when it is a single
    /// web or app URL and nothing else. Returns the notes unchanged and `nil` otherwise.
    public static func splitTrailingURL(_ notes: String) -> (body: String, url: String?) {
        var lines = notes.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let last = lines.last else { return (notes, nil) }
        let candidate = last.trimmingCharacters(in: .whitespaces)
        guard isLinkURL(candidate) else { return (notes, nil) }
        lines.removeLast()
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return (lines.joined(separator: "\n"), candidate)
    }

    /// Adds `url` as the last line of Things notes, after a blank line, unless the notes already
    /// contain it anywhere (inline links count).
    public static func appendingURL(_ url: String, to notes: String) -> String {
        if notes.contains(url) { return notes }
        let body = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? url : body + "\n\n" + url
    }

    /// True for a single absolute URL with a scheme and no spaces: https://…, http://…, or an app
    /// link such as obsidian://… (the forms Reminders accepts as a rich link).
    public static func isLinkURL(_ s: String) -> Bool {
        guard !s.isEmpty, !s.contains(where: \.isWhitespace),
              let comps = URLComponents(string: s), let scheme = comps.scheme, !scheme.isEmpty,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else { return false }
        if scheme == "http" || scheme == "https" { return !(comps.host ?? "").isEmpty }
        return s.hasPrefix(scheme + "://")
    }

    /// Renders Things Markdown as the plain text Reminders shows. Conservative on purpose: only
    /// syntax that would otherwise show as stray characters is rewritten, and text is never dropped.
    /// - `[text](url)` → `text (url)`, or just `url` when the text is the URL itself.
    /// - `**bold**`, `__bold__`, `*italic*`, `~~strike~~`, `` `code` `` → the inner text.
    /// - Leading `#` heading markers are removed. List markers and quotes are kept; they read fine.
    public static func plainText(fromMarkdown markdown: String) -> String {
        markdown.components(separatedBy: "\n").map(plainLine).joined(separator: "\n")
    }

    private static func plainLine(_ line: String) -> String {
        var s = line
        if let r = s.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) { s.removeSubrange(r) }
        s = replace(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#, in: s) { g in
            let text = g[1], url = g[2]
            return text == url ? url : "\(text) (\(url))"
        }
        // Inline code first, so emphasis markers inside code are left alone.
        s = replace(#"`([^`\n]+)`"#, in: s) { $0[1] }
        s = replace(#"\*\*(\S(?:[^*\n]*\S)?)\*\*"#, in: s) { $0[1] }
        s = replace(#"(?<![\w])__(\S(?:[^_\n]*\S)?)__(?![\w])"#, in: s) { $0[1] }
        s = replace(#"~~(\S(?:[^~\n]*\S)?)~~"#, in: s) { $0[1] }
        // Single-asterisk italics only; `_x_` is left alone because underscores are common in
        // file names and URLs.
        s = replace(#"(?<![\w*])\*(\S(?:[^*\n]*\S)?)\*(?![\w*])"#, in: s) { $0[1] }
        return s
    }

    private static func replace(_ pattern: String, in s: String, with transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += transform(groups)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
