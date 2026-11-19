import Foundation

/// One problem a checker found in the buffer.
public struct CheckProblem: Equatable, Sendable {
    public enum Severity: Equatable, Sendable { case error, warning }
    public var line: Int
    public var column: Int?
    public var message: String
    public var severity: Severity

    public init(line: Int, column: Int? = nil, message: String, severity: Severity) {
        self.line = max(line, 1)
        self.column = column
        self.message = message
        self.severity = severity
    }
}

/// The tools found on a server (one discovery exec per connection).
public struct ServerTools: Equatable, Sendable {
    /// Tool name to the absolute path `command -v` reported.
    public var paths: [String: String]
    /// Absolute paths of `php-fpm*` binaries (versioned ones such as `/usr/sbin/php-fpm8.2`).
    public var fpmBinaries: [String]

    public init(paths: [String: String] = [:], fpmBinaries: [String] = []) {
        self.paths = paths
        self.fpmBinaries = fpmBinaries
    }

    public func path(_ name: String) -> String? { paths[name] }

    /// One exec that prints `tool <name> <path>` and `fpm <path>` lines. The sbin folders are added to the search
    /// path because a non-login SSH session on most distributions does not have them.
    public static let discoveryCommand = """
        sh -c 'PATH="$PATH:/usr/sbin:/usr/local/sbin:/sbin:/usr/local/bin"; \
        for t in php nginx apachectl apache2ctl httpd php-fpm python3 node jq shellcheck yamllint; do \
        p=$(command -v "$t" 2>/dev/null) && [ -n "$p" ] && echo "tool $t $p"; done; \
        for f in /usr/sbin/php-fpm* /usr/local/sbin/php-fpm*; do [ -x "$f" ] && echo "fpm $f"; done; true'
        """

    public static func parse(_ output: String) -> ServerTools {
        var tools = ServerTools()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            if parts.count == 3, parts[0] == "tool", parts[2].hasPrefix("/") {
                tools.paths[parts[1]] = parts[2]
            } else if parts.count >= 2, parts[0] == "fpm" {
                let path = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("/"), !tools.fpmBinaries.contains(path) { tools.fpmBinaries.append(path) }
            }
        }
        tools.fpmBinaries.sort()
        return tools
    }
}

/// How the output of a checker is read.
public enum CheckParser: Equatable, Sendable {
    case php, python, node(fileName: String), shell, shellcheck, jq, yamllint
}

/// One command to run with the buffer on stdin.
public struct EditorCheckStep: Equatable, Sendable {
    /// What the log and the bar call it: "php -l", "bash -n", "shellcheck".
    public var label: String
    public var command: String
    public var parser: CheckParser
}

public enum EditorCheckPlan: Equatable, Sendable {
    /// Run these in order; stop after the first step that finds an error.
    case run([EditorCheckStep])
    /// Checked right here.
    case local(label: String, problems: [CheckProblem])
    /// There is a checker for this file but the server lacks it ("no yamllint on server").
    case unavailable(String)
    /// Nothing to check for this kind of file.
    case none
}

public enum EditorChecks {
    // MARK: Plans

    public static func plan(
        for file: FileClassification, fileName: String, path: String, text: String, tools: ServerTools
    ) -> EditorCheckPlan {
        let q = ShellWord.quote
        switch file.kind {
        case .php:
            guard let php = tools.path("php") else { return .unavailable("no php on server") }
            // display_errors=1 + log_errors=0 makes the message come out once, on stdout, whatever php.ini says.
            return .run([EditorCheckStep(
                label: "php -l", command: "\(q(php)) -d display_errors=1 -d log_errors=0 -d html_errors=0 -l", parser: .php)])
        case .python:
            guard let python = tools.path("python3") else { return .unavailable("no python3 on server") }
            return .run([EditorCheckStep(
                label: "python3 compile", command: "\(q(python)) -c \(q(pythonScript))", parser: .python)])
        case .javascript:
            let ext = (fileName.lowercased() as NSString).pathExtension
            guard ["js", "mjs", "cjs"].contains(ext) else { return .none }
            guard let node = tools.path("node") else { return .unavailable("no node on server") }
            let module = ext == "mjs" || (ext == "js" && looksLikeModule(text))
            let temp = "c." + (module ? "mjs" : ext)
            // A directory, not a bare mktemp file: newer node refuses files without a known extension.
            let command = "d=$(mktemp -d) && cat > \"$d/\(temp)\" && \(q(node)) --check \"$d/\(temp)\" 2>&1; r=$?; rm -rf \"$d\"; exit $r"
            return .run([EditorCheckStep(label: "node --check", command: "sh -c \(q(command))", parser: .node(fileName: fileName))])
        case .shell:
            guard file.dialect != .other else { return .none }
            let shell = file.dialect == .sh ? "sh" : "bash"
            var steps = [EditorCheckStep(label: "\(shell) -n", command: "\(shell) -n", parser: .shell)]
            if let shellcheck = tools.path("shellcheck") {
                steps.append(EditorCheckStep(
                    label: "shellcheck", command: "\(q(shellcheck)) -S warning -s \(shell) -f gcc -", parser: .shellcheck))
            }
            return .run(steps)
        case .json:
            if let jq = tools.path("jq") {
                return .run([EditorCheckStep(label: "jq empty", command: "\(q(jq)) empty", parser: .jq)])
            }
            let problems = JSONFormatter.validate(text).map {
                [CheckProblem(line: $0.line, column: $0.column, message: $0.message, severity: .error)]
            } ?? []
            return .local(label: "built-in JSON check", problems: problems)
        case .yaml:
            guard let yamllint = tools.path("yamllint") else { return .unavailable("no yamllint on server") }
            return .run([EditorCheckStep(
                label: "yamllint", command: "\(q(yamllint)) -f parsable -", parser: .yamllint)])
        case .crontab:
            // /etc/crontab and /etc/cron.d/* have a user column the parser would reject; only user crontabs are checked.
            guard !path.hasPrefix("/etc/cron") else { return .none }
            let problems = Crontab(parsing: text).issues.map {
                CheckProblem(line: $0.line, message: $0.message, severity: .error)
            }
            return .local(label: "crontab parser", problems: problems)
        default:
            return .none
        }
    }

    static let pythonScript = """
        import sys
        src = sys.stdin.buffer.read()
        try:
            compile(src, "<stdin>", "exec", dont_inherit=True)
        except SyntaxError as e:
            print("%s:%s:%s" % (e.lineno or 1, e.offset or 0, e.msg))
            sys.exit(1)
        except ValueError as e:
            print("1:0:%s" % e)
            sys.exit(1)
        """

    /// `import x from` / `export ...` at the start of a line: needs to be parsed as an ES module.
    static func looksLikeModule(_ text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("export ") || (trimmed.hasPrefix("import ") && !trimmed.hasPrefix("import(")) { return true }
        }
        return false
    }

    // MARK: Parsing

    public enum StepOutcome: Equatable, Sendable {
        case problems([CheckProblem])
        /// The tool did something unexpected (crashed, timed out of ideas); the file counts as not checked.
        case inconclusive(String)
    }

    public static func outcome(of step: EditorCheckStep, stdout: String, stderr: String, status: Int32) -> StepOutcome {
        let combined = stdout + "\n" + stderr
        let problems: [CheckProblem]
        switch step.parser {
        case .php: problems = parsePHP(combined)
        case .python: problems = parsePython(stdout)
        case .node(let fileName): problems = parseNode(combined, fileName: fileName)
        case .shell: problems = parseShell(combined)
        case .shellcheck: problems = parseShellcheck(stdout)
        case .jq: problems = parseJQ(combined)
        case .yamllint: problems = parseYamllint(stdout)
        }
        if problems.isEmpty, status != 0, step.parser != .shellcheck {
            let first = combined.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
            return .inconclusive("\(step.label) exited with status \(status)" + (first.map { ": \($0)" } ?? ""))
        }
        return .problems(problems)
    }

    /// `Parse error: syntax error, unexpected token "echo" in Standard input code on line 4` (also `PHP Parse error:  ...`).
    static func parsePHP(_ output: String) -> [CheckProblem] {
        var found: [CheckProblem] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("PHP ") { line.removeFirst(4) }
            let severity: CheckProblem.Severity
            if line.hasPrefix("Parse error:") || line.hasPrefix("Fatal error:") {
                severity = .error
            } else if line.hasPrefix("Warning:") || line.hasPrefix("Deprecated:") || line.hasPrefix("Notice:") {
                severity = .warning
            } else {
                continue
            }
            guard let colon = line.firstIndex(of: ":"), let on = line.range(of: " on line ", options: .backwards),
                  let number = Int(line[on.upperBound...].trimmingCharacters(in: .whitespaces).prefix(while: \.isNumber))
            else { continue }
            var message = String(line[line.index(after: colon)..<on.lowerBound]).trimmingCharacters(in: .whitespaces)
            if let location = message.range(of: " in ", options: .backwards) { message = String(message[..<location.lowerBound]) }
            let problem = CheckProblem(line: number, message: message, severity: severity)
            if !found.contains(problem) { found.append(problem) }
        }
        return found
    }

    /// `line:column:message`, printed by `pythonScript`.
    static func parsePython(_ output: String) -> [CheckProblem] {
        for raw in output.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let line = Int(parts[0]), let column = Int(parts[1]) else { continue }
            return [CheckProblem(line: line, column: column > 0 ? column : nil, message: String(parts[2]), severity: .error)]
        }
        return []
    }

    /// ```
    /// /tmp/tmp.X/c.js:2
    /// let x = ;
    ///         ^
    ///
    /// SyntaxError: Unexpected token ';'
    /// ```
    static func parseNode(_ output: String, fileName: String) -> [CheckProblem] {
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        for (index, line) in lines.enumerated() {
            guard let colon = line.lastIndex(of: ":"), let number = Int(line[line.index(after: colon)...]),
                  line[..<colon].hasSuffix(".js") || line[..<colon].hasSuffix(".mjs") || line[..<colon].hasSuffix(".cjs")
                    || line[..<colon] == "[stdin]"
            else { continue }
            let tempPath = String(line[..<colon])
            var column: Int?
            if index + 2 < lines.count, let caret = lines[index + 2].firstIndex(of: "^"),
               lines[index + 2].allSatisfy({ $0 == " " || $0 == "^" || $0 == "\t" }) {
                column = lines[index + 2].distance(from: lines[index + 2].startIndex, to: caret) + 1
            }
            var message = "Syntax error"
            for later in lines[(index + 1)...] where later.hasPrefix("SyntaxError:") {
                message = String(later.dropFirst("SyntaxError:".count)).trimmingCharacters(in: .whitespaces)
                break
            }
            message = message.replacingOccurrences(of: tempPath, with: fileName)
            return [CheckProblem(line: number, column: column, message: message, severity: .error)]
        }
        return []
    }

    /// `bash: line 4: syntax error near unexpected token `fi'` (the following quoted-source line is dropped).
    static func parseShell(_ output: String) -> [CheckProblem] {
        var found: [CheckProblem] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let range = line.range(of: ": line ") else { continue }
            let rest = line[range.upperBound...]
            guard let colon = rest.firstIndex(of: ":"), let number = Int(rest[..<colon]) else { continue }
            let message = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if message.hasPrefix("`") || message.isEmpty { continue }
            found.append(CheckProblem(line: number, message: message, severity: .error))
        }
        return found
    }

    /// `-:2:8: warning: Use "${var:?}" ... [SC2115]` (`gcc` format). Everything is reported as a warning: style advice
    /// never blocks a save, and real syntax errors are `bash -n`'s job.
    static func parseShellcheck(_ output: String) -> [CheckProblem] {
        var found: [CheckProblem] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, parts[0] == "-", let line = Int(parts[1]), let column = Int(parts[2]) else { continue }
            let severity = parts[3].trimmingCharacters(in: .whitespaces)
            guard severity == "warning" || severity == "error" else { continue }
            found.append(CheckProblem(
                line: line, column: column, message: parts[4].trimmingCharacters(in: .whitespaces), severity: .warning))
        }
        return found
    }

    /// `jq: error (at <stdin>:0): ...` is a runtime error; `jq: parse error: <msg> at line 2, column 6` is a syntax one.
    static func parseJQ(_ output: String) -> [CheckProblem] {
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard line.hasPrefix("jq: error") || line.hasPrefix("jq: parse error") || line.contains("parse error") else { continue }
            var message = line
            if let colon = line.range(of: "parse error: ") { message = String(line[colon.upperBound...]) }
            var number = 1, column: Int?
            if let at = message.range(of: " at line ", options: .backwards) {
                let tail = message[at.upperBound...]
                let pieces = tail.components(separatedBy: ", column ")
                number = Int(pieces[0]) ?? 1
                if pieces.count > 1, let c = Int(pieces[1]) { column = c > 0 ? c : nil }
                message = String(message[..<at.lowerBound])
            }
            return [CheckProblem(line: number, column: column, message: message, severity: .error)]
        }
        return []
    }

    /// `stdin:3:10: [error] syntax error: mapping values are not allowed here (syntax)`. Only syntax errors block a
    /// save; style findings (trailing spaces, line length, truthy values) are warnings whatever yamllint calls them.
    static func parseYamllint(_ output: String) -> [CheckProblem] {
        var found: [CheckProblem] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, let line = Int(parts[1]), let column = Int(parts[2]) else { continue }
            var message = parts[3].trimmingCharacters(in: .whitespaces)
            let isSyntax = message.hasSuffix("(syntax)")
            for level in ["[error] ", "[warning] "] where message.hasPrefix(level) { message.removeFirst(level.count) }
            found.append(CheckProblem(
                line: line, column: column, message: message, severity: isSyntax ? .error : .warning))
        }
        return found
    }

    // MARK: Config tests

    public struct ConfigTest: Equatable, Sendable {
        /// "nginx -t".
        public var label: String
        public var command: String
        public var successNote: String
    }

    public enum ConfigTestPlan: Equatable, Sendable {
        case test(ConfigTest)
        /// A config of that kind, but the server has no binary to test it with.
        case unavailable(String)
        case none
    }

    /// The test to run after saving a web-server config. Only files in a system config tree qualify: testing the
    /// server's live config after editing a copy in a home folder would say nothing about the copy.
    public static func configTest(for kind: EditorFileKind, path: String, tools: ServerTools) -> ConfigTestPlan {
        let q = ShellWord.quote
        let systemTrees = ["/etc/", "/usr/local/etc/", "/usr/local/nginx/", "/opt/", "/usr/local/apache"]
        guard systemTrees.contains(where: { path.hasPrefix($0) }) else { return .none }
        switch kind {
        case .nginx:
            guard let nginx = tools.path("nginx") else { return .unavailable("no nginx on server") }
            return .test(ConfigTest(label: "nginx -t", command: "\(q(nginx)) -t", successNote: "nginx -t: syntax OK"))
        case .apache:
            if let ctl = tools.path("apachectl") ?? tools.path("apache2ctl") {
                let name = (ctl as NSString).lastPathComponent
                return .test(ConfigTest(
                    label: "\(name) configtest", command: "\(q(ctl)) configtest", successNote: "\(name) configtest: Syntax OK"))
            }
            if let httpd = tools.path("httpd") {
                return .test(ConfigTest(label: "httpd -t", command: "\(q(httpd)) -t", successNote: "httpd -t: Syntax OK"))
            }
            return .unavailable("no apachectl on server")
        case .phpFpm:
            guard let binary = fpmBinary(forPath: path, tools: tools) else { return .unavailable("no php-fpm on server") }
            let name = (binary as NSString).lastPathComponent
            return .test(ConfigTest(label: "\(name) -t", command: "\(q(binary)) -t", successNote: "\(name) -t: OK"))
        default:
            return .none
        }
    }

    /// `/etc/php/8.2/fpm/pool.d/www.conf` goes with `php-fpm8.2`; otherwise the plain binary, else the newest versioned one.
    static func fpmBinary(forPath path: String, tools: ServerTools) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(of: "php"), index + 1 < parts.count {
            let version = parts[index + 1]
            if let match = tools.fpmBinaries.first(where: { ($0 as NSString).lastPathComponent == "php-fpm\(version)" }) { return match }
        }
        if let plain = tools.path("php-fpm") { return plain }
        return tools.fpmBinaries.last
    }

    public enum ConfigTestResult: Equatable, Sendable {
        case ok
        case failed([String])
        case needsRoot
    }

    public static func interpretConfigTest(stdout: String, stderr: String, status: Int32, elevated: Bool) -> ConfigTestResult {
        if status == 0 { return .ok }
        let lines = (stderr + "\n" + stdout).split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let lower = lines.joined(separator: "\n").lowercased()
        if !elevated, ["permission denied", "(13:", "must be root", "need to be root", "operation not permitted", "run as root"]
            .contains(where: lower.contains) {
            return .needsRoot
        }
        let markers = ["emerg", "error", "ah0", "syntax", "failed", "unknown", "invalid", "unexpected", "not found", "cannot"]
        var meaningful = lines.filter { line in
            let l = line.lowercased()
            return !l.contains("ah00558") && markers.contains(where: l.contains)
        }
        if meaningful.isEmpty { meaningful = lines }
        let cleaned = meaningful.prefix(3).map { line -> String in
            var text = line
            // php-fpm prefixes `[12-Nov-2026 10:00:00] `.
            if text.hasPrefix("["), let close = text.firstIndex(of: "]"), text[text.startIndex...close].contains(":") {
                text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            return text.count > 200 ? String(text.prefix(200)) + "\u{2026}" : text
        }
        return .failed(cleaned.isEmpty ? ["The test failed (exit status \(status))."] : Array(cleaned))
    }
}
