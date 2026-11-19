import Foundation

/// Shells the editor hook can be defined in. fish, csh and tcsh have no POSIX functions, so they get nothing.
public enum HookShell: Equatable, Sendable {
    case bash, zsh, posix

    /// From a `$SHELL` path such as `/bin/bash`. Nil only for shells known to lack POSIX functions (fish, csh,
    /// tcsh and the like). Anything else is tried as POSIX: `$SHELL` is often a wrapper (mysecureshell, rssh,
    /// lshell) that starts bash, and if the line fails, its ready marker never comes and the hiding times out.
    public static func detect(shellPath: String) -> HookShell? {
        let name = shellPath.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").last.map(String.init) ?? ""
        switch name {
        case "bash": return .bash
        case "zsh": return .zsh
        case "fish", "csh", "tcsh", "nu", "xonsh", "elvish", "pwsh", "rc", "es": return nil
        default: return .posix
        }
    }
}

/// The shell script (a short first line, then the body) that makes `nano file`, `vim file`, `sudo vim file`, `sudoedit` and `crontab -e` ask
/// Dockyard what to do. The user's own command runs as typed, so the history keeps it.
public enum EditorShellHook {
    /// OSC the functions print: kind, editor, user@host, `$PWD`, argument count, then each argument, DEL-separated.
    public static let requestOSC = 7733
    /// OSC the injection line ends with, so Dockyard knows when it is done.
    public static let readyOSC = 7734
    public static let readyMarker: [UInt8] = Array("\u{1B}]\(readyOSC);ready\u{07}".utf8)
    /// OSC the short first line prints just before `cat` starts reading: the shell is ready for the script body.
    public static let goMarker: [UInt8] = Array("\u{1B}]\(readyOSC);go\u{07}".utf8)
    /// Ends the body: EOF for `cat` in the terminal's canonical mode.
    public static let endOfBody = "\u{04}"
    public static let separator: Character = "\u{7F}"

    /// What Dockyard types into the function's blocking `read`. `e`: handled, return. Anything else: run the real one.
    public static let handledReply = "e\r"
    public static let runRealReply = "r\r"

    public static let editors = ["nano", "pico", "vi", "vim", "nvim", "emacs", "micro", "joe", "jed", "mcedit", "ne", "hx", "kak"]

    /// Phase one: the only text that goes through the shell's line editor. It reports `go`, then `cat` reads the body
    /// from the terminal (kernel line discipline, no line editor) and `eval` runs it in this shell. Leading space for
    /// HISTCONTROL=ignorespace; no final Return.
    public static func goLine() -> String {
        #" printf '\033]7734;go\007'; eval "$(cat)""#
    }

    /// Phase two: the script, one statement per line, each far below the 4095-byte canonical line limit. Send each
    /// line followed by a newline, then `endOfBody`.
    public static func bodyLines() -> [String] {
        let names = editors.joined(separator: " ")
        let pattern = editors.joined(separator: "|")
        var parts: [String] = []
        // The helper. $1 kind, $2 command name, rest the arguments. It reports, then blocks on one line from the
        // terminal with echo off. An interrupt returns 130 without running anything and leaves the terminal as it was:
        // bash and zsh get that from `read -s`, the others from `stty` and a trap.
        let guardLine = #"if [ ! -t 0 ] || [ ! -t 1 ]; then command "$_dn" "$@"; return $?; fi; "#
        let report =
            #"printf '\033]7733;%s\177%s\177%s@%s\177%s\177%s' "$_dk" "$_dn" "$(id -un)" "$(hostname)" "$PWD" "$#"; "#
            + #"printf '\177%s' "$@"; printf '\007'; _dr=; "#
        // Where `read -s` exists (bash, zsh, including `sh` that is bash) it does the restoring itself.
        let wait = #"if [ -n "$BASH_VERSION$ZSH_VERSION" ]; then "# + report
            + #"IFS= read -rs _dr || return 130; else "#
            + #"_ds=$(stty -g 2>/dev/null) || { command "$_dn" "$@"; return $?; }; "#
            + #"trap 'stty "$_ds" 2>/dev/null' INT; stty -echo 2>/dev/null; "#
            + report
            + #"IFS= read -r _dr || { stty "$_ds" 2>/dev/null; trap - INT; return 130; }; "#
            + #"stty "$_ds" 2>/dev/null; trap - INT; fi; "#
        parts.append(
            #"__dy_ed() { _dk=$1; _dn=$2; shift 2; "# + guardLine + wait
            + #"case $_dr in e) return 0;; esac; command "$_dn" "$@"; }"#)
        // Names the user aliased are left alone. `eval` keeps the definition from being parsed with the alias applied.
        parts.append(
            #"for _dn in \#(names); do alias "$_dn" >/dev/null 2>&1 || eval "$_dn() { __dy_ed edit $_dn \"\$@\"; }"; done"#)
        parts.append(
            #"alias sudoedit >/dev/null 2>&1 || eval 'sudoedit() { __dy_ed sudo sudoedit "$@"; }'"#)
        parts.append(
            #"alias sudo >/dev/null 2>&1 || eval 'sudo() { case "$1" in \#(pattern)|-e) __dy_ed sudo sudo "$@";; *) command sudo "$@";; esac; }'"#)
        parts.append(
            #"alias crontab >/dev/null 2>&1 || eval 'crontab() { if [ $# -eq 1 ] && [ "$1" = -e ]; then __dy_ed crontab crontab -e; else command crontab "$@"; fi; }'"#)
        do {
            // Bash adds the short line to the history before running it. Drop it, but only if it really is the last
            // entry (HISTCONTROL=ignorespace never added it, and then the last entry is the user's own).
            parts.append(
                #"[ -n "$BASH_VERSION" ] && case "$(HISTTIMEFORMAT= history 1 2>/dev/null)" in *7734\;go*) history -d $(HISTTIMEFORMAT= history 1 | sed 's/^ *\([0-9]*\).*/\1/') 2>/dev/null;; esac"#)
        }
        parts.append(#"printf '\033]7734;ready\007'"#)
        return parts
    }
}

/// A request the shell functions sent over OSC 7733.
public struct EditorRequest: Equatable, Sendable {
    public enum Kind: String, Sendable { case edit, sudo, crontab }

    public let kind: Kind
    /// The command the user ran: `nano`, `sudo`, `sudoedit`, `crontab`.
    public let name: String
    public let user: String
    public let host: String
    public let directory: String
    /// The arguments after the shell expanded them.
    public let arguments: [String]

    /// Parses `kind DEL name DEL user@host DEL pwd DEL count DEL arg…`. Nil when anything is off, including an
    /// argument count that does not match (an argument containing a control character cut the report short).
    public static func parse(payload: String) -> EditorRequest? {
        let fields = payload.split(separator: EditorShellHook.separator, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5, let kind = Kind(rawValue: fields[0]), !fields[1].isEmpty,
              let at = fields[2].lastIndex(of: "@"), let count = Int(fields[4]), count >= 0,
              fields.count == 5 + count else { return nil }
        let who = fields[2]
        return EditorRequest(
            kind: kind, name: fields[1], user: String(who[..<at]), host: String(who[who.index(after: at)...]),
            directory: fields[3], arguments: Array(fields.dropFirst(5)))
    }

    /// The command as the file/editor rules see it. Nil when Dockyard should not take it.
    public var command: EditorCommand? {
        EditorCommand.parse(words: [name] + arguments)
    }
}

/// How the user wants editor commands handled.
public enum EditorHandling: Equatable, Sendable {
    case inline, macEditor, runInTerminal
}

public enum EditorDecision: Equatable, Sendable {
    case openInline(path: String, line: Int?, sudo: Bool)
    case openMacEditor(path: String, sudo: Bool)
    case editCrontab
    /// Reply `r`: the function runs the real command.
    case runReal

    /// `directory` is `$PWD` from the request; the file may be relative to it.
    public static func decide(_ request: EditorRequest, handling: EditorHandling) -> EditorDecision {
        guard handling != .runInTerminal, let command = request.command else { return .runReal }
        switch command {
        case .crontab:
            return .editCrontab
        case .edit(_, let file, let line, let sudo):
            guard let path = absolutePath(file, in: request.directory) else { return .runReal }
            return handling == .inline ? .openInline(path: path, line: line, sudo: sudo) : .openMacEditor(path: path, sudo: sudo)
        }
    }

    /// Makes `path` absolute against `directory` and drops `.` and `..`.
    public static func absolutePath(_ path: String, in directory: String) -> String? {
        let full = path.hasPrefix("/") ? path : directory + "/" + path
        guard full.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in full.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
}

/// Hides the shell's output from sending the short line until the ready marker, then redraws cleanly. Two phases:
/// waiting for `go` (the controller then sends the body, see `takeGo()`), then waiting for `ready`.
public struct InjectionOutputFilter: Sendable {
    public private(set) var isHiding = false
    /// True from the `go` marker on: the body has been (or is being) sent.
    public private(set) var goSeen = false
    private var goPending = false
    private var held: [UInt8] = []
    /// The last bytes hidden, so a hook line that fails can be explained in the log (usually the shell's error).
    public private(set) var recentlyHidden: [UInt8] = []

    public init() {}

    public mutating func begin() {
        isHiding = true
        goSeen = false
        goPending = false
        held = []
        recentlyHidden = []
    }

    /// Gives up hiding (timeout).
    public mutating func abort() {
        isHiding = false
        goSeen = false
        goPending = false
        held = []
    }

    /// True once, after the `go` marker arrived: the caller should now send the script body.
    public mutating func takeGo() -> Bool {
        defer { goPending = false }
        return goPending
    }

    /// The hidden output's last line or two as plain text, escape sequences removed.
    public var hiddenSummary: String {
        let text = String(decoding: recentlyHidden, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]|\u{1B}[()][0-9A-Za-z]|\u{1B}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.suffix(2).joined(separator: " / ")
    }

    /// Bytes to show. While hiding, nothing until the ready marker arrives; then `CR` + erase-line (it removes the old
    /// prompt, which the shell is about to draw again) and whatever followed the marker. The `go` marker only sets
    /// `takeGo()`; hiding goes on (the terminal echoes the body).
    public mutating func process(_ bytes: [UInt8]) -> [UInt8] {
        guard isHiding else { return bytes }
        held += bytes
        recentlyHidden = Array((recentlyHidden + bytes).suffix(600))
        if !goSeen, let range = Self.find(EditorShellHook.goMarker, in: held) {
            goSeen = true
            goPending = true
            held = Array(held[range.upperBound...])
        }
        let marker = EditorShellHook.readyMarker
        if let range = Self.find(marker, in: held) {
            let rest = Array(held[range.upperBound...])
            held = []
            isHiding = false
            return Array("\r\u{1B}[K".utf8) + rest
        }
        // Keep only what could still turn into a marker.
        let longest = max(marker.count, EditorShellHook.goMarker.count)
        if held.count >= longest { held = Array(held.suffix(longest - 1)) }
        return []
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if Array(haystack[start..<start + needle.count]) == needle { return start..<start + needle.count }
        }
        return nil
    }
}
