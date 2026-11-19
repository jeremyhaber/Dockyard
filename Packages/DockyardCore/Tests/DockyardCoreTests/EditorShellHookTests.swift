import Testing
@testable import DockyardCore

@Suite struct EditorShellHookTests {
    private func payload(_ fields: [String]) -> String { fields.joined(separator: "\u{7F}") }

    @Test func shellDetection() {
        #expect(HookShell.detect(shellPath: "/bin/bash\n") == .bash)
        #expect(HookShell.detect(shellPath: "/usr/bin/zsh") == .zsh)
        #expect(HookShell.detect(shellPath: "/bin/dash") == .posix)
        #expect(HookShell.detect(shellPath: "/bin/sh") == .posix)
        #expect(HookShell.detect(shellPath: "/usr/bin/fish") == nil)
        #expect(HookShell.detect(shellPath: "/bin/tcsh") == nil)
        // Unknown names, usually wrappers that start bash, are tried as POSIX.
        #expect(HookShell.detect(shellPath: "/usr/bin/mysecureshell\n") == .posix)
        #expect(HookShell.detect(shellPath: "") == .posix)
    }

    @Test func goLineIsShort() {
        let line = EditorShellHook.goLine()
        #expect(line.hasPrefix(" "))
        #expect(!line.contains("\n"))
        #expect(line.utf8.count < 100)
        #expect(line.contains("7734;go"))
        #expect(line.hasSuffix(#"eval "$(cat)""#))
    }

    @Test func scriptContent() {
        let lines = EditorShellHook.bodyLines()
        let body = lines.joined(separator: "\n")
        #expect(!lines.isEmpty)
        for line in lines {
            #expect(!line.contains("\n"))
            #expect(line.utf8.count < 2000)
            #expect(!line.contains("\u{04}"))
        }
        for name in EditorShellHook.editors { #expect(body.contains(" \(name)")) }
        for needle in ["sudoedit()", "sudo()", "crontab()", "__dy_ed()", "command \"$_dn\" \"$@\"", "read -rs", "stty -g", "7733", "7734;ready"] {
            #expect(body.contains(needle), "missing \(needle)")
        }
        // Wrappers only act on editors and `crontab -e`; everything else is the real command.
        #expect(body.contains("command sudo \"$@\""))
        #expect(body.contains("command crontab \"$@\""))
        // Aliased names are left alone and the history line is dropped only in bash, matched on the short line.
        #expect(body.contains("alias \"$_dn\""))
        #expect(body.contains("[ -n \"$BASH_VERSION\" ] && case"))
        #expect(body.contains("history -d"))
        #expect(body.contains(#"*7734\;go*"#))
        #expect(lines.last == #"printf '\033]7734;ready\007'"#)
        // No passwords or file contents anywhere in it.
        #expect(!body.lowercased().contains("password"))
    }

    @Test func parsesRequests() {
        let request = EditorRequest.parse(payload: payload(["edit", "nano", "jeremy@web1", "/srv/www", "2", "a b.txt", "+3"]))
        #expect(request == EditorRequest(kind: .edit, name: "nano", user: "jeremy", host: "web1", directory: "/srv/www", arguments: ["a b.txt", "+3"]))
        #expect(EditorRequest.parse(payload: payload(["crontab", "crontab", "u@h", "/", "1", "-e"]))?.kind == .crontab)
        #expect(EditorRequest.parse(payload: payload(["edit", "vi", "u@h", "/", "0"]))?.arguments == [])
    }

    @Test func rejectsMalformedRequests() {
        #expect(EditorRequest.parse(payload: "") == nil)
        #expect(EditorRequest.parse(payload: payload(["edit", "nano", "u@h", "/", "1"])) == nil)           // count says 1, none sent
        #expect(EditorRequest.parse(payload: payload(["edit", "nano", "u@h", "/", "1", "a", "b"])) == nil) // extra field
        #expect(EditorRequest.parse(payload: payload(["bogus", "nano", "u@h", "/", "0"])) == nil)
        #expect(EditorRequest.parse(payload: payload(["edit", "nano", "nohost", "/", "0"])) == nil)
        #expect(EditorRequest.parse(payload: payload(["edit", "nano", "u@h", "/", "x"])) == nil)
    }

    private func request(_ kind: EditorRequest.Kind, _ name: String, _ args: [String], dir: String = "/srv") -> EditorRequest {
        EditorRequest(kind: kind, name: name, user: "u", host: "h", directory: dir, arguments: args)
    }

    @Test func decisions() {
        #expect(EditorDecision.decide(request(.edit, "nano", ["a.txt"]), handling: .inline) == .openInline(path: "/srv/a.txt", line: nil, sudo: false))
        #expect(EditorDecision.decide(request(.edit, "vim", ["+12", "../etc/x"]), handling: .inline) == .openInline(path: "/etc/x", line: 12, sudo: false))
        #expect(EditorDecision.decide(request(.edit, "nano", ["-w", "a b"]), handling: .macEditor) == .openMacEditor(path: "/srv/a b", sudo: false))
        #expect(EditorDecision.decide(request(.sudo, "sudo", ["vim", "/etc/hosts"]), handling: .inline) == .openInline(path: "/etc/hosts", line: nil, sudo: true))
        #expect(EditorDecision.decide(request(.sudo, "sudo", ["-e", "f"]), handling: .inline) == .openInline(path: "/srv/f", line: nil, sudo: true))
        #expect(EditorDecision.decide(request(.sudo, "sudoedit", ["f"]), handling: .inline) == .openInline(path: "/srv/f", line: nil, sudo: true))
        #expect(EditorDecision.decide(request(.crontab, "crontab", ["-e"]), handling: .macEditor) == .editCrontab)
    }

    @Test func decisionsThatRunTheRealCommand() {
        #expect(EditorDecision.decide(request(.edit, "nano", ["a.txt"]), handling: .runInTerminal) == .runReal)
        #expect(EditorDecision.decide(request(.edit, "nano", []), handling: .inline) == .runReal)
        #expect(EditorDecision.decide(request(.edit, "nano", ["a", "b"]), handling: .inline) == .runReal)
        #expect(EditorDecision.decide(request(.edit, "vim", ["-O", "a"]), handling: .inline) == .runReal)
        #expect(EditorDecision.decide(request(.edit, "vim", ["-"]), handling: .inline) == .runReal)
        #expect(EditorDecision.decide(request(.sudo, "sudo", ["ls"]), handling: .inline) == .runReal)
        #expect(EditorDecision.decide(request(.crontab, "crontab", ["-l"]), handling: .inline) == .runReal)
        #expect(EditorDecision.decide(request(.edit, "nano", ["a"], dir: "relative"), handling: .inline) == .runReal)
    }

    @Test func outputFilterHidesUntilMarker() {
        var filter = InjectionOutputFilter()
        #expect(filter.process(Array("shown".utf8)) == Array("shown".utf8))
        filter.begin()
        #expect(filter.process(Array(" echo of the line\r\n".utf8)).isEmpty)
        let marker = EditorShellHook.readyMarker
        // The marker split across chunks still ends the hiding.
        #expect(filter.process(Array(marker[0..<4])).isEmpty)
        let out = filter.process(Array(marker[4...]) + Array("PROMPT$ ".utf8))
        #expect(String(decoding: out, as: UTF8.self) == "\r\u{1B}[KPROMPT$ ")
        #expect(!filter.isHiding)
        #expect(filter.process(Array("x".utf8)) == Array("x".utf8))
    }

    @Test func outputFilterTwoPhases() {
        var filter = InjectionOutputFilter()
        filter.begin()
        #expect(filter.process(Array("echo \u{1B}(B of the short line\r\n".utf8)).isEmpty)
        let again1 = filter.takeGo(); #expect(!again1)
        // `go` split across chunks: the controller is told once, hiding goes on.
        let go = EditorShellHook.goMarker
        #expect(filter.process(Array(go[0..<5])).isEmpty)
        let again2 = filter.takeGo(); #expect(!again2)
        #expect(filter.process(Array(go[5...]) + Array("echoed body\r\n".utf8)).isEmpty)
        let got = filter.takeGo(); #expect(got)
        let again3 = filter.takeGo(); #expect(!again3)
        #expect(filter.isHiding)
        // The body's echo may mention the ready text as plain characters; only the real marker ends hiding.
        #expect(filter.process(Array("printf '\\033]7734;ready\\007'\r\n".utf8)).isEmpty)
        #expect(filter.isHiding)
        let ready = EditorShellHook.readyMarker
        #expect(filter.process(Array(ready[0..<7])).isEmpty)
        let out = filter.process(Array(ready[7...]) + Array("PROMPT$ ".utf8))
        #expect(String(decoding: out, as: UTF8.self) == "\r\u{1B}[KPROMPT$ ")
        #expect(!filter.isHiding)
        let again4 = filter.takeGo(); #expect(!again4)
    }

    @Test func outputFilterSummaryAfterAbort() {
        var filter = InjectionOutputFilter()
        filter.begin()
        _ = filter.process(Array("\u{1B}(Bline one\r\n\u{1B}[0mbash: oops\r\n".utf8))
        filter.abort()
        #expect(filter.hiddenSummary == "line one / bash: oops")
    }

    @Test func outputFilterAbort() {
        var filter = InjectionOutputFilter()
        filter.begin()
        _ = filter.process(Array("junk".utf8))
        filter.abort()
        #expect(!filter.isHiding)
        #expect(filter.process(Array("a".utf8)) == Array("a".utf8))
    }
}
