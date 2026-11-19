import Foundation
import Testing
@testable import DockyardCore

// MARK: Comment toggle

@Suite struct CommentToggleTests {
    private func apply(_ text: String, _ selection: NSRange, _ kind: EditorFileKind) -> (String, NSRange)? {
        guard let edit = CommentToggle.toggle(text: text, selection: selection, kind: kind) else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        return (result, edit.selection)
    }

    @Test func commentsTheCaretLineAtItsIndent() {
        let (text, selection) = apply("<?php\n    b\n", NSRange(location: 10, length: 0), .php)!
        #expect(text == "<?php\n    // b\n")
        #expect(selection == NSRange(location: 13, length: 0))
    }

    @Test func togglesBackAndRestoresTheCaret() {
        let (text, selection) = apply("<?php\n    // b\n", NSRange(location: 14, length: 0), .php)!
        #expect(text == "<?php\n    b\n")
        #expect(selection == NSRange(location: 11, length: 0))
    }

    @Test func usesTheMinimumIndentAndSkipsBlankLines() {
        let source = "    a\n\n  b\n      c\n"
        let (text, _) = apply(source, NSRange(location: 0, length: source.utf16.count - 1), .shell)!
        #expect(text == "  #   a\n\n  # b\n  #     c\n")
    }

    @Test func partlyCommentedSelectionCommentsEverything() {
        let (text, _) = apply("# a\nb\n", NSRange(location: 0, length: 5), .python)!
        #expect(text == "# # a\n# b\n")
    }

    @Test func allCommentedUncomments() {
        let (text, _) = apply("# a\n\n#b\n", NSRange(location: 0, length: 7), .yaml)!
        #expect(text == "a\n\nb\n")
    }

    @Test func selectionEndingAtLineStartLeavesThatLineOut() {
        let (text, _) = apply("a\nb\nc\n", NSRange(location: 0, length: 4), .conf)!
        #expect(text == "# a\n# b\nc\n")
    }

    @Test func markersPerType() {
        #expect(apply("x", NSRange(location: 0, length: 0), .phpIni)!.0 == "; x")
        #expect(apply("x", NSRange(location: 0, length: 0), .sql)!.0 == "-- x")
        #expect(apply("x", NSRange(location: 0, length: 0), .lua)!.0 == "-- x")
        #expect(apply("x", NSRange(location: 0, length: 0), .javascript)!.0 == "// x")
        #expect(apply("x", NSRange(location: 0, length: 0), .nginx)!.0 == "# x")
        #expect(apply("x", NSRange(location: 0, length: 0), .dockerfile)!.0 == "# x")
        #expect(apply("x", NSRange(location: 0, length: 0), .json) == nil)
    }

    @Test func cssAndHTMLWrapEachLine() {
        let (css, _) = apply("a {}\n  b {}\n", NSRange(location: 0, length: 11), .css)!
        #expect(css == "/* a {} */\n/*   b {} */\n")
        let (back, _) = apply(css, NSRange(location: 0, length: css.utf16.count - 1), .css)!
        #expect(back == "a {}\n  b {}\n")
        let (html, _) = apply("<p>x</p>\n", NSRange(location: 0, length: 0), .html)!
        #expect(html == "<!-- <p>x</p> -->\n")
        #expect(apply(html, NSRange(location: 0, length: 0), .html)!.0 == "<p>x</p>\n")
    }

    @Test func phpUsesHTMLCommentsOutsideTheTag() {
        let source = "<div>x</div>\n<?php\n$a = 1;\n?>\n<p>y</p>\n"
        let html = apply(source, NSRange(location: 0, length: 0), .php)!.0
        #expect(html.hasPrefix("<!-- <div>x</div> -->\n<?php"))
        let php = apply(source, NSRange(location: 20, length: 0), .php)!.0
        #expect(php.contains("// $a = 1;"))
        let after = (source as NSString).range(of: "<p>").location
        #expect(apply(source, NSRange(location: after, length: 0), .php)!.0.contains("<!-- <p>y</p> -->"))
    }

    @Test func selectionGrowsWithTheMarkers() {
        let (text, selection) = apply("ab\ncd\n", NSRange(location: 1, length: 4), .shell)!
        #expect(text == "# ab\n# cd\n")
        #expect(selection == NSRange(location: 3, length: 6))
    }
}

// MARK: Classification

@Suite struct FileClassificationTests {
    private func kind(_ path: String, first: String = "") -> EditorFileKind {
        FileClassification.detect(fileName: (path as NSString).lastPathComponent, path: path, firstLine: first).kind
    }

    @Test func byName() {
        #expect(kind("/var/www/index.php") == .php)
        #expect(kind("/home/u/.htaccess") == .htaccess)
        #expect(kind("/etc/php/8.2/fpm/php.ini") == .phpIni)
        #expect(kind("/home/u/Dockerfile") == .dockerfile)
        #expect(kind("/home/u/app/.env.production") == .env)
        #expect(kind("/home/u/crontab") == .crontab)
        #expect(kind("/srv/nginx.conf") == .nginx)
        #expect(kind("/srv/data.json") == .json)
        #expect(kind("/srv/q.sql") == .sql)
    }

    @Test func byFolder() {
        #expect(kind("/etc/nginx/sites-enabled/default") == .nginx)
        #expect(kind("/etc/apache2/sites-available/000-default.conf") == .apache)
        #expect(kind("/etc/httpd/conf.d/ssl.conf") == .apache)
        #expect(kind("/etc/php/8.2/fpm/pool.d/www.conf") == .phpFpm)
        #expect(kind("/etc/php-fpm.d/www.conf") == .phpFpm)
        #expect(kind("/etc/php/8.2/fpm/conf.d/20-opcache.ini") == .phpIni)
        #expect(kind("/etc/cron.d/backup") == .crontab)
    }

    @Test func byShebang() {
        #expect(kind("/usr/local/bin/deploy", first: "#!/bin/bash") == .shell)
        #expect(kind("/usr/local/bin/run", first: "#!/usr/bin/env python3") == .python)
        #expect(kind("/usr/local/bin/t", first: "#!/usr/bin/env node") == .javascript)
        #expect(kind("/usr/local/bin/t", first: "#!/usr/bin/php") == .php)
        #expect(kind("/usr/local/bin/notes") == .plain)
        let sh = FileClassification.detect(fileName: "x", path: "/x", firstLine: "#!/bin/sh")
        #expect(sh.dialect == .sh)
        #expect(FileClassification.detect(fileName: ".zshrc", path: "/h/.zshrc").dialect == .other)
    }

    @Test func quoting() {
        #expect(ShellWord.quote("it's") == "'it'\\''s'")
    }
}

// MARK: Checkers (sample outputs captured from php 8.3, python 3.14, node 26, bash 5, shellcheck 0.11, jq 1.7)

@Suite struct EditorChecksTests {
    private func step(_ parser: CheckParser) -> EditorCheckStep { EditorCheckStep(label: "t", command: "t", parser: parser) }

    @Test func phpDedupesAndReadsLine() {
        let out = """
        PHP Parse error:  syntax error, unexpected token "echo" in Standard input code on line 4

        Parse error: syntax error, unexpected token "echo" in Standard input code on line 4
        Errors parsing Standard input code
        """
        let result = EditorChecks.outcome(of: step(.php), stdout: out, stderr: "", status: 255)
        #expect(result == .problems([CheckProblem(line: 4, message: "syntax error, unexpected token \"echo\"", severity: .error)]))
        let unclosed = "Parse error: Unclosed '{' on line 2 in Standard input code on line 4\nErrors parsing Standard input code\n"
        #expect(EditorChecks.parsePHP(unclosed).first?.message == "Unclosed '{' on line 2")
        #expect(EditorChecks.outcome(of: step(.php), stdout: "No syntax errors detected in Standard input code\n", stderr: "", status: 0) == .problems([]))
    }

    @Test func python() {
        let p = EditorChecks.parsePython("3:1:expected an indented block after 'if' statement on line 2\n")
        #expect(p == [CheckProblem(line: 3, column: 1, message: "expected an indented block after 'if' statement on line 2", severity: .error)])
    }

    @Test func node() {
        let out = """
        /var/folders/6g/T/tmp.VMz9njNYWM/c.js:2
        let x = ;
                ^

        SyntaxError: Unexpected token ';'
            at wrapSafe (node:internal/modules/cjs/loader:1866:18)

        Node.js v26.8.1
        """
        let p = EditorChecks.parseNode(out, fileName: "app.js")
        #expect(p == [CheckProblem(line: 2, column: 9, message: "Unexpected token ';'", severity: .error)])
        #expect(EditorChecks.outcome(of: step(.node(fileName: "a.js")), stdout: "", stderr: "", status: 1) != .problems([]))
    }

    @Test func shell() {
        let out = "bash: line 4: syntax error near unexpected token `fi'\nbash: line 4: `fi'\n"
        #expect(EditorChecks.parseShell(out) == [CheckProblem(line: 4, message: "syntax error near unexpected token `fi'", severity: .error)])
        #expect(EditorChecks.parseShell("sh: line 4: syntax error: unexpected end of file\n").first?.line == 4)
    }

    @Test func shellcheckIsWarningsOnly() {
        let out = """
        -:2:8: warning: Use "${var:?}" to ensure this never expands to /* . [SC2115]
        -:3:1: error: Couldn't parse this for loop. Fix to allow more checks. [SC1073]
        -:3:6: note: Double quote to prevent globbing and word splitting. [SC2086]
        """
        let p = EditorChecks.parseShellcheck(out)
        #expect(p.count == 2)
        #expect(p.allSatisfy { $0.severity == .warning })
        #expect(p[0].line == 2 && p[0].column == 8)
    }

    @Test func jq() {
        let p = EditorChecks.parseJQ("jq: parse error: Unmatched '}' at line 2, column 6\n")
        #expect(p == [CheckProblem(line: 2, column: 6, message: "Unmatched '}'", severity: .error)])
        #expect(EditorChecks.parseJQ("jq: parse error: Invalid numeric literal at line 2, column 0\n").first?.column == nil)
    }

    @Test func yamllintOnlySyntaxBlocks() {
        let out = "stdin:2:3: [error] syntax error: mapping values are not allowed here (syntax)\nstdin:1:7: [error] trailing spaces (trailing-spaces)\nstdin:1:1: [warning] missing document start \"---\" (document-start)\n"
        let p = EditorChecks.parseYamllint(out)
        #expect(p.map(\.severity) == [.error, .warning, .warning])
        #expect(p[0].message == "syntax error: mapping values are not allowed here (syntax)")
    }

    @Test func plans() {
        let tools = ServerTools(paths: ["php": "/usr/bin/php", "jq": "/usr/bin/jq"])
        let php = EditorChecks.plan(for: .init(kind: .php), fileName: "a.php", path: "/a.php", text: "", tools: tools)
        guard case .run(let steps) = php else { Issue.record("expected a run"); return }
        #expect(steps[0].command.hasPrefix("'/usr/bin/php' "))
        #expect(EditorChecks.plan(for: .init(kind: .yaml), fileName: "a.yml", path: "/a.yml", text: "", tools: tools) == .unavailable("no yamllint on server"))
        #expect(EditorChecks.plan(for: .init(kind: .plain), fileName: "a", path: "/a", text: "", tools: tools) == .none)
        let noJq = EditorChecks.plan(for: .init(kind: .json), fileName: "a.json", path: "/a.json", text: "{\"a\":}", tools: ServerTools())
        guard case .local(_, let problems) = noJq else { Issue.record("expected local"); return }
        #expect(problems.first?.line == 1)
        let cron = EditorChecks.plan(for: .init(kind: .crontab), fileName: "crontab", path: "/home/u/crontab", text: "nonsense\n", tools: tools)
        guard case .local(_, let cronProblems) = cron else { Issue.record("expected local"); return }
        #expect(!cronProblems.isEmpty)
        #expect(EditorChecks.plan(for: .init(kind: .crontab), fileName: "crontab", path: "/etc/crontab", text: "x", tools: tools) == .none)
    }

    @Test func discoveryOutput() {
        let tools = ServerTools.parse("tool php /usr/bin/php\ntool nginx /usr/sbin/nginx\nfpm /usr/sbin/php-fpm8.1\nfpm /usr/sbin/php-fpm8.2\ngarbage\n")
        #expect(tools.path("nginx") == "/usr/sbin/nginx")
        #expect(tools.fpmBinaries == ["/usr/sbin/php-fpm8.1", "/usr/sbin/php-fpm8.2"])
    }

    @Test func configTests() {
        let tools = ServerTools(paths: ["nginx": "/usr/sbin/nginx", "apache2ctl": "/usr/sbin/apache2ctl"],
                                fpmBinaries: ["/usr/sbin/php-fpm8.1", "/usr/sbin/php-fpm8.2"])
        #expect(EditorChecks.configTest(for: .nginx, path: "/etc/nginx/nginx.conf", tools: tools)
            == .test(.init(label: "nginx -t", command: "'/usr/sbin/nginx' -t", successNote: "nginx -t: syntax OK")))
        #expect(EditorChecks.configTest(for: .nginx, path: "/home/u/nginx.conf", tools: tools) == .none)
        if case .test(let apache) = EditorChecks.configTest(for: .apache, path: "/etc/apache2/apache2.conf", tools: tools) {
            #expect(apache.command == "'/usr/sbin/apache2ctl' configtest")
        } else { Issue.record("apache") }
        if case .test(let fpm) = EditorChecks.configTest(for: .phpFpm, path: "/etc/php/8.1/fpm/pool.d/www.conf", tools: tools) {
            #expect(fpm.command == "'/usr/sbin/php-fpm8.1' -t")
        } else { Issue.record("fpm") }
        #expect(EditorChecks.configTest(for: .htaccess, path: "/etc/x/.htaccess", tools: tools) == .none)
    }

    @Test func configResults() {
        #expect(EditorChecks.interpretConfigTest(stdout: "", stderr: "nginx: configuration file /etc/nginx/nginx.conf test is successful", status: 0, elevated: false) == .ok)
        let denied = "nginx: [alert] could not open error log file: open() \"/var/log/nginx/error.log\" failed (13: Permission denied)\nnginx: [emerg] open() \"/run/nginx.pid\" failed (13: Permission denied)"
        #expect(EditorChecks.interpretConfigTest(stdout: "", stderr: denied, status: 1, elevated: false) == .needsRoot)
        let bad = "nginx: [emerg] unknown directive \"foo\" in /etc/nginx/nginx.conf:5\nnginx: configuration file /etc/nginx/nginx.conf test failed"
        guard case .failed(let lines) = EditorChecks.interpretConfigTest(stdout: "", stderr: bad, status: 1, elevated: true) else { Issue.record("expected failure"); return }
        #expect(lines.first == "nginx: [emerg] unknown directive \"foo\" in /etc/nginx/nginx.conf:5")
        let fpm = "[12-Nov-2026 10:00:00] ERROR: [pool www] cannot get uid for user 'nobody'"
        guard case .failed(let fpmLines) = EditorChecks.interpretConfigTest(stdout: "", stderr: fpm, status: 78, elevated: true) else { Issue.record("fpm"); return }
        #expect(fpmLines == ["ERROR: [pool www] cannot get uid for user 'nobody'"])
    }
}

// MARK: JSON

@Suite struct JSONFormatterTests {
    @Test func keepsOrderEscapesAndNumberText() throws {
        let source = "{\"b\":1.50,\"a\":\"\\u00e9\\n\\/\",\"c\":[1e5,-0.0,true,null,{}],\"d\":[]}"
        let out = try JSONFormatter.format(source)
        #expect(out == "{\n  \"b\": 1.50,\n  \"a\": \"\\u00e9\\n\\/\",\n  \"c\": [\n    1e5,\n    -0.0,\n    true,\n    null,\n    {}\n  ],\n  \"d\": []\n}")
    }

    @Test func detectsIndentAndKeepsTrailingNewline() throws {
        #expect(JSONFormatter.detectIndent(in: "{\n    \"a\": 1\n}\n") == "    ")
        #expect(JSONFormatter.detectIndent(in: "{\n\t\"a\": 1\n}\n") == "\t")
        #expect(JSONFormatter.detectIndent(in: "{\"a\":1}") == "  ")
        let out = try JSONFormatter.format("{\n    \"a\":[1,2]\n}\n")
        #expect(out == "{\n    \"a\": [\n        1,\n        2\n    ]\n}\n")
    }

    @Test func formattingIsIdempotent() throws {
        let once = try JSONFormatter.format("[{\"a\":{\"b\":[1,2,{\"c\":null}]}},\"x\"]")
        #expect(try JSONFormatter.format(once) == once)
    }

    @Test func reportsErrorsWithPosition() {
        #expect(JSONFormatter.validate("{\n  \"a\": 1,\n}")?.line == 3)
        #expect(JSONFormatter.validate("{\"a\" 1}")?.column == 6)
        #expect(JSONFormatter.validate("[1,]") != nil)
        #expect(JSONFormatter.validate("{} {}") != nil)
        #expect(JSONFormatter.validate("// c\n{}") != nil)
        #expect(JSONFormatter.validate("{\"a\":01}") != nil)
        #expect(JSONFormatter.validate("[\"a\nb\"]") != nil)
        #expect(JSONFormatter.validate("[1") != nil)
        #expect(JSONFormatter.validate("  [1, 2 ]  \n") == nil)
    }
}
