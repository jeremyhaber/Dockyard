import ConnectionKit
import DockyardCore
import Foundation

// MARK: - Cron editor

extension AppModel {
    /// The command runner behind a connection's cron editor, or nil for FTP and cloud connections.
    func cronRunner(for session: ConnectionSession) -> (any RemoteCommandRunner)? {
        if DemoMode.isEnabled {
            return session.connection.protocol == .sftp ? DemoCronRunner.shared(for: session.connection) : nil
        }
        return session.fs as? any RemoteCommandRunner
    }

    /// True when the session is connected over SSH, so `crontab` can be run on the server.
    func canEditCron(_ session: ConnectionSession) -> Bool {
        session.status.isConnected && cronRunner(for: session) != nil
    }

    /// Shows the cron editor sheet for `session`. Also what the terminal calls when the user types `crontab -e`.
    func openCronEditor(for session: ConnectionSession) {
        guard canEditCron(session) else {
            alertMessage = session.status.isConnected
                ? "Cron jobs can only be edited on SFTP (SSH) connections."
                : "Connect to \(session.connection.name) first."
            return
        }
        activate(session)
        safety.cronSessionID = session.id
    }

    var cronSession: ConnectionSession? {
        safety.cronSessionID.flatMap { id in sessions.first { $0.id == id } }
    }
}
