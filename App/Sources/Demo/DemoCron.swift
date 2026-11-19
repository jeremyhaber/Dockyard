import ConnectionKit
import DockyardCore
import Foundation

/// Stands in for `crontab` on a demo server: keeps one crontab per connection in memory, so the cron
/// editor can be opened, edited and saved in screenshots with no network.
final class DemoCronRunner: RemoteCommandRunner, @unchecked Sendable {
    private static let registry = LockedBox<[UUID: DemoCronRunner]>([:])

    static func shared(for connection: Connection) -> DemoCronRunner {
        registry.withLock { runners in
            if let existing = runners[connection.id] { return existing }
            let runner = DemoCronRunner(text: sample(for: connection))
            runners[connection.id] = runner
            return runner
        }
    }

    private let text: LockedBox<String>
    private init(text: String) { self.text = LockedBox(text) }

    static func sample(for connection: Connection) -> String {
        """
        # Edit this file to introduce tasks to be run by cron.
        # m h  dom mon dow   command
        MAILTO=ops@\(connection.host.isEmpty ? "example.com" : connection.host)
        SHELL=/bin/bash
        PATH=/usr/local/bin:/usr/bin:/bin

        # Nightly database backup
        30 2 * * * /usr/local/bin/backup-db.sh >> /var/log/backup.log 2>&1

        # Renew TLS certificates
        0 4 * * 1 certbot renew --quiet --deploy-hook "systemctl reload nginx"

        # Clear the page cache
        0 */6 * * * /usr/bin/php /var/www/artisan cache:clear

        # Weekday sales digest
        15 8 * * 1-5 /usr/bin/php /var/www/artisan reports:digest

        # Rotate uploads on the first of the month
        45 1 1 * * /usr/local/bin/rotate-uploads.sh

        # Ping the uptime monitor
        # */5 * * * * curl -fsS https://status.example.com/ping/abc123 > /dev/null

        @reboot /usr/local/bin/start-queue-worker.sh
        """ + "\n"
    }

    func exec(_ command: String) async throws -> SSHExecResult {
        SSHExecResult(exitStatus: 127)
    }

    func execStream(_ command: String, elevated: Bool) async throws -> AsyncThrowingStream<SSHExecEvent, Error> {
        try await execStream(command, elevated: elevated, stdin: nil)
    }

    func execStream(_ command: String, elevated: Bool, stdin: Data?) async throws -> AsyncThrowingStream<SSHExecEvent, Error> {
        let events: [SSHExecEvent]
        switch command {
        case "crontab -l":
            events = [.stdout(Data(text.withLock { $0 }.utf8)), .exit(0)]
        case "crontab -":
            text.withLock { $0 = String(decoding: stdin ?? Data(), as: UTF8.self) }
            events = [.exit(0)]
        case _ where command.hasPrefix("date"):
            events = [.stdout(Data("2026-10-25 12:00:00 +0000 UTC\n".utf8)), .exit(0)]
        default:
            events = [.stderr(Data("demo: command not available\n".utf8)), .exit(127)]
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
