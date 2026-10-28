import Foundation

extension SSHSession {
    static let sftpServerPaths = [
        "/usr/lib/openssh/sftp-server",
        "/usr/libexec/openssh/sftp-server",
        "/usr/lib/ssh/sftp-server",
        "/usr/libexec/sftp-server",
    ]

    private static let readyMarker = "DKYD-READY"

    /// Starts the `sftp` subsystem as the logged-in user.
    func openSFTP() async throws -> SFTPClient {
        try await perform { session in
            let channel = try session.newChannel()
            do {
                try channel.startSubsystem("sftp")
                let client = SFTPClient(session: session, channel: channel)
                try client.handshake()
                return client
            } catch {
                channel.close()
                throw error
            }
        }
    }

    /// Path of the first `sftp-server` binary found on the remote host.
    func findSFTPServer() async throws -> String? {
        let tests = Self.sftpServerPaths.map { "[ -x \($0) ] && echo \($0) && exit 0" }.joined(separator: "; ")
        let result = try await exec(tests + "; exit 1")
        let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Speaks SFTP to an `sftp-server` started as root through `sudo -S` (or `sudo -n` without a stored
    /// password) or through `su`. The password only travels over the encrypted channel and is never logged.
    func openElevatedSFTP(kind: Elevation, password: String?) async throws -> SFTPClient {
        guard kind != .none else { throw RemoteError.invalidConfiguration("No elevation method selected") }
        guard let server = try await findSFTPServer() else {
            throw RemoteError.unsupported("No sftp-server binary found in \(Self.sftpServerPaths.joined(separator: ", "))")
        }
        if kind == .su, password == nil { throw RemoteError.authenticationFailed("No su password stored") }

        let inner = "printf \"\(Self.readyMarker)\\n\"; exec \(server)"
        let channel = try await perform { session in
            let channel = try session.newChannel()
            do {
                switch kind {
                case .sudo:
                    try channel.exec(password == nil ? "sudo -n sh -c '\(inner)'" : "sudo -S -p '' sh -c '\(inner)'")
                    if let password { try channel.write(Array((password + "\n").utf8)) }
                case .su:
                    try channel.requestPTY(cols: 80, rows: 24, term: "dumb")
                    try channel.exec("su root -c 'stty raw -echo; \(inner)'")
                case .none:
                    break
                }
            } catch {
                channel.close()
                throw error
            }
            return channel
        }

        do {
            let prefill = try await waitForReady(channel, kind: kind, password: password)
            let client = try await perform { session in
                let client = SFTPClient(session: session, channel: channel, prefill: prefill)
                try client.handshake()
                return client
            }
            return client
        } catch {
            try? await perform { _ in channel.close() }
            throw error
        }
    }

    /// Reads until the ready marker, answering su's password prompt. Returns bytes that followed the marker.
    private func waitForReady(_ channel: SSHChannel, kind: Elevation, password: String?) async throws -> [UInt8] {
        let marker = Data((Self.readyMarker + "\n").utf8)
        var stdout = Data()
        var stderr = Data()
        var answered = kind != .su
        let limit = Date().addingTimeInterval(20)
        let sudoErrors = ["sorry, try again", "incorrect password", "password is required", "not in the sudoers", "may not run sudo"]

        while true {
            let chunk = try await perform { _ in try channel.readSome(wait: 0.2) }
            stdout.append(chunk.stdout)
            stderr.append(chunk.stderr)

            if !answered, let password, String(decoding: stdout, as: UTF8.self).lowercased().contains("assword") {
                answered = true
                try await perform { _ in try channel.write(Array((password + "\n").utf8)) }
            }
            if let range = stdout.range(of: marker) { return [UInt8](stdout[range.upperBound...]) }

            let errorText = String(decoding: stderr, as: UTF8.self).lowercased()
            if chunk.isEOF || sudoErrors.contains(where: errorText.contains) || Date() > limit {
                let text = (stderr + stdout).isEmpty ? "no output" : String(decoding: stderr + stdout, as: UTF8.self)
                let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty && !$0.lowercased().hasPrefix("password") } ?? "no output"
                throw RemoteError.authenticationFailed("\(kind == .su ? "su" : "sudo"): \(line.prefix(120))")
            }
        }
    }
}
