import Foundation

/// What a highlighted span is. The editor maps each kind to a colour.
public enum SyntaxKind: Sendable {
    case comment, string, number, keyword, key, variable, tag
}

public struct SyntaxSpan: Equatable, Sendable {
    /// UTF-16 offsets within the line, so they can be used as NSRange directly.
    public var start: Int
    public var length: Int
    public var kind: SyntaxKind
}

public enum SyntaxLanguage: Sendable, CaseIterable {
    case plain, shell, php, javascript, json, yaml, ini, nginx, python, html, css, crontab

    /// Picks a language from the file name (`.env`, `nginx.conf`, `*.sh`, ...). Plain text when unknown.
    public static func detect(fileName: String, path: String = "") -> SyntaxLanguage {
        let name = fileName.lowercased()
        let ext = name.split(separator: ".").count > 1 ? String(name.split(separator: ".").last ?? "") : ""
        if name == "crontab" || path.hasPrefix("/etc/cron") || path.hasPrefix("/var/spool/cron") { return .crontab }
        if name.hasPrefix(".env") || name == "env" { return .ini }
        if ["sh", "bash", "zsh", "ksh", "profile", "bashrc", "zshrc", "bash_profile", "bash_aliases"].contains(ext)
            || [".bashrc", ".zshrc", ".profile", ".bash_profile", ".bash_aliases"].contains(name) { return .shell }
        if name == "nginx.conf" || name.hasSuffix(".nginx") || path.contains("/nginx/") { return .nginx }
        if name == ".htaccess" || name == "httpd.conf" || name == "apache2.conf" || path.contains("/apache2/")
            || path.contains("/httpd/") { return .nginx }
        switch ext {
        case "php", "phtml", "inc": return .php
        case "js", "jsx", "mjs", "cjs", "ts", "tsx": return .javascript
        case "json", "jsonc", "webmanifest": return .json
        case "yml", "yaml": return .yaml
        case "ini", "conf", "cfg", "env", "properties", "toml", "service", "cnf": return .ini
        case "py": return .python
        case "html", "htm", "xml", "svg", "xhtml", "twig": return .html
        case "css", "scss", "less": return .css
        default: return .plain
        }
    }
}

/// A small line-by-line highlighter: comments, strings, numbers, a few keywords and language specifics. It keeps no
/// state between lines, so a block comment or string that spans lines only colours its first line. That is the
/// trade for re-highlighting just the edited paragraph.
public enum SyntaxHighlighter {
    public static func spans(in line: String, language: SyntaxLanguage) -> [SyntaxSpan] {
        guard language != .plain else { return [] }
        let chars = Array(line.utf16)
        guard !chars.isEmpty else { return [] }
        var scanner = Scanner(chars: chars, spec: spec(for: language), language: language)
        scanner.run()
        return scanner.spans
    }

    // MARK: Language tables

    struct Spec {
        var lineComments: [String] = []
        var block: (open: String, close: String)?
        var quotes: [UInt16] = [0x22, 0x27]
        var keywords: Set<String> = []
        var variables = false
        var wordCommentsNeedSpace = false
    }

    private static func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }

    static func spec(for language: SyntaxLanguage) -> Spec {
        switch language {
        case .plain: Spec()
        case .shell:
            Spec(lineComments: ["#"], keywords: words("if then else elif fi for while until do done case esac in function select return exit local export readonly source alias unset set shift break continue eval exec trap"), variables: true, wordCommentsNeedSpace: true)
        case .php:
            Spec(lineComments: ["//", "#"], block: ("/*", "*/"), keywords: words("<?php ?> function class interface trait extends implements namespace use public private protected static final abstract const new return if else elseif endif foreach endforeach for while do switch case break continue default try catch finally throw echo print require require_once include include_once define null true false array isset empty unset global fn match as instanceof"), variables: true)
        case .javascript:
            Spec(lineComments: ["//"], block: ("/*", "*/"), quotes: [0x22, 0x27, 0x60], keywords: words("function class extends const let var return if else for while do switch case break continue default try catch finally throw new import export from as async await yield typeof instanceof in of null undefined true false this super interface type enum implements public private protected readonly static void"))
        case .json:
            Spec(keywords: words("true false null"))
        case .yaml:
            Spec(lineComments: ["#"], keywords: words("true false null yes no on off"), wordCommentsNeedSpace: true)
        case .ini:
            Spec(lineComments: ["#", ";"], keywords: words("true false yes no on off null"), variables: true, wordCommentsNeedSpace: true)
        case .nginx:
            Spec(lineComments: ["#"], keywords: words("on off true false"), variables: true, wordCommentsNeedSpace: true)
        case .python:
            Spec(lineComments: ["#"], keywords: words("def class return if elif else for while in not and or is import from as with try except finally raise pass break continue lambda yield global nonlocal assert del None True False async await self"))
        case .html:
            Spec(block: ("<!--", "-->"))
        case .css:
            Spec(block: ("/*", "*/"), keywords: words("important"))
        case .crontab:
            Spec(lineComments: ["#"], keywords: words("@reboot @hourly @daily @weekly @monthly @yearly @annually @midnight"), variables: false, wordCommentsNeedSpace: true)
        }
    }

    // MARK: Scanner

    struct Scanner {
        let chars: [UInt16]
        let spec: Spec
        let language: SyntaxLanguage
        var spans: [SyntaxSpan] = []
        var i = 0

        init(chars: [UInt16], spec: Spec, language: SyntaxLanguage) {
            self.chars = chars
            self.spec = spec
            self.language = language
        }

        private func isWordStart(_ c: UInt16) -> Bool { c == 0x5F || c == 0x40 || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        private func isWord(_ c: UInt16) -> Bool { isWordStart(c) || isDigit(c) || c == 0x2D && language != .javascript && language != .php && language != .python }
        private func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
        private func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 }

        private func matches(_ text: String, at index: Int) -> Bool {
            let units = Array(text.utf16)
            guard index + units.count <= chars.count else { return false }
            for (offset, unit) in units.enumerated() where chars[index + offset] != unit { return false }
            return true
        }

        private mutating func add(_ start: Int, _ end: Int, _ kind: SyntaxKind) {
            guard end > start else { return }
            spans.append(SyntaxSpan(start: start, length: end - start, kind: kind))
        }

        private var firstNonSpace: Int { chars.firstIndex { !isSpace($0) } ?? chars.count }

        mutating func run() {
            // Whole-line forms first.
            switch language {
            case .yaml: yamlKey()
            case .ini: iniLine()
            case .nginx: directive()
            case .css: cssProperty()
            default: break
            }
            while i < chars.count {
                let c = chars[i]
                if let comment = spec.lineComments.first(where: { matches($0, at: i) }),
                   !spec.wordCommentsNeedSpace || i == 0 || isSpace(chars[i - 1]) || comment != "#" && comment != ";" {
                    add(i, chars.count, .comment)
                    return
                }
                if let block = spec.block, matches(block.open, at: i) {
                    let closeAt = find(block.close, from: i + block.open.utf16.count)
                    let end = closeAt.map { $0 + block.close.utf16.count } ?? chars.count
                    add(i, end, .comment)
                    i = end
                    continue
                }
                if spec.quotes.contains(c) {
                    stringLiteral(quote: c)
                    continue
                }
                if language == .html, c == 0x3C { htmlTag(); continue }
                if spec.variables, c == 0x24 { variable(); continue }
                if isDigit(c), i == 0 || !isWord(chars[i - 1]) { number(); continue }
                if isWordStart(c) || (c == 0x3C && language == .php) || (c == 0x3F && language == .php) {
                    word()
                    continue
                }
                i += 1
            }
        }

        private func find(_ text: String, from: Int) -> Int? {
            var index = from
            while index < chars.count {
                if matches(text, at: index) { return index }
                index += 1
            }
            return nil
        }

        private mutating func stringLiteral(quote: UInt16) {
            let start = i
            i += 1
            while i < chars.count {
                if chars[i] == 0x5C { i += 2; continue }
                if chars[i] == quote { i += 1; break }
                i += 1
            }
            i = min(i, chars.count)
            // JSON and JS object keys: a string followed by a colon.
            var after = i
            while after < chars.count, isSpace(chars[after]) { after += 1 }
            let isKey = (language == .json || language == .yaml) && after < chars.count && chars[after] == 0x3A
            add(start, i, isKey ? .key : .string)
        }

        private mutating func number() {
            let start = i
            while i < chars.count, isDigit(chars[i]) || chars[i] == 0x2E || chars[i] == 0x78
                || (chars[i] >= 0x61 && chars[i] <= 0x66) || (chars[i] >= 0x41 && chars[i] <= 0x46) { i += 1 }
            // A digit run glued to letters ("3rd", "a1b") is a word, not a number.
            if i < chars.count, isWord(chars[i]) {
                while i < chars.count, isWord(chars[i]) { i += 1 }
                return
            }
            add(start, i, .number)
        }

        private mutating func word() {
            let start = i
            // `<?php` and `?>`.
            if language == .php, chars[start] == 0x3C || chars[start] == 0x3F {
                if matches("<?php", at: start) { i = start + 5; add(start, i, .keyword) }
                else if matches("?>", at: start) { i = start + 2; add(start, i, .keyword) }
                else { i = start + 1 }
                return
            }
            i += 1
            while i < chars.count, isWord(chars[i]) { i += 1 }
            let text = String(utf16CodeUnits: Array(chars[start..<i]), count: i - start)
            if spec.keywords.contains(text) { add(start, i, .keyword) }
        }

        private mutating func variable() {
            let start = i
            i += 1
            if i < chars.count, chars[i] == 0x7B {
                while i < chars.count, chars[i] != 0x7D { i += 1 }
                i = min(i + 1, chars.count)
            } else {
                while i < chars.count, isWord(chars[i]) && chars[i] != 0x2D { i += 1 }
            }
            if i > start + 1 { add(start, i, .variable) } else { i = start + 1 }
        }

        private mutating func htmlTag() {
            let start = i
            while i < chars.count, chars[i] != 0x3E { i += 1 }
            i = min(i + 1, chars.count)
            add(start, i, .tag)
        }

        // MARK: Whole-line forms

        /// `key: value` (also `- key: value`): colours the key and leaves the value to the main scan.
        private mutating func yamlKey() {
            var start = firstNonSpace
            if start < chars.count, chars[start] == 0x2D, start + 1 < chars.count, isSpace(chars[start + 1]) {
                start += 1
                while start < chars.count, isSpace(chars[start]) { start += 1 }
            }
            guard start < chars.count, isWordStart(chars[start]) || isDigit(chars[start]) else { return }
            var end = start
            while end < chars.count, chars[end] != 0x3A, chars[end] != 0x23 { end += 1 }
            guard end < chars.count, chars[end] == 0x3A, end + 1 == chars.count || isSpace(chars[end + 1]) else { return }
            add(start, end, .key)
            i = end + 1
        }

        /// `[section]` and `key = value`.
        private mutating func iniLine() {
            let start = firstNonSpace
            guard start < chars.count else { return }
            if chars[start] == 0x5B {
                var end = start
                while end < chars.count, chars[end] != 0x5D { end += 1 }
                end = min(end + 1, chars.count)
                add(start, end, .tag)
                i = end
                return
            }
            if spec.lineComments.contains(where: { matches($0, at: start) }) { return }
            var end = start
            while end < chars.count, chars[end] != 0x3D { end += 1 }
            guard end < chars.count else { return }
            var keyEnd = end
            while keyEnd > start, isSpace(chars[keyEnd - 1]) { keyEnd -= 1 }
            add(start, keyEnd, .key)
            i = end + 1
        }

        /// The first word of an nginx or Apache line is the directive (`listen`, `RewriteRule`, `<VirtualHost`).
        private mutating func directive() {
            let start = firstNonSpace
            guard start < chars.count, chars[start] != 0x23 else { return }
            var end = start
            if chars[end] == 0x3C { end += 1 }
            while end < chars.count, !isSpace(chars[end]), chars[end] != 0x3E, chars[end] != 0x7B, chars[end] != 0x3B { end += 1 }
            add(start, end, .keyword)
            i = end
        }

        /// `property: value;` inside a CSS rule.
        private mutating func cssProperty() {
            let start = firstNonSpace
            guard start < chars.count, isWordStart(chars[start]) || chars[start] == 0x2D else { return }
            var end = start
            while end < chars.count, isWord(chars[end]) || chars[end] == 0x2D { end += 1 }
            var after = end
            while after < chars.count, isSpace(chars[after]) { after += 1 }
            guard after < chars.count, chars[after] == 0x3A, !(after + 1 < chars.count && chars[after + 1] == 0x3A) else { return }
            add(start, end, .key)
            i = after + 1
        }
    }
}
