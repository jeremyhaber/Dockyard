import ConnectionKit
import Foundation

/// In-memory files for the terminal editor in demo mode: a few canned configs, saves kept for the session.
final class DemoEditorStore: EditorFileStore, @unchecked Sendable {
    static let shared = DemoEditorStore()

    private let files = LockedBox<[String: Data]>([:])

    func stat(_ path: String) async throws -> RemoteItem? {
        guard let data = contents(of: path) else { return nil }
        return RemoteItem(
            name: RemotePath.lastComponent(of: path), path: path, isDirectory: false, size: UInt64(data.count),
            modified: DemoMode.anchor.addingTimeInterval(-86_400), permissions: 0o644)
    }

    func read(_ path: String) async throws -> Data {
        guard let data = contents(of: path) else { throw RemoteError.notFound(path) }
        return data
    }

    func write(_ data: Data, to path: String) async throws {
        files.withLock { $0[path] = data }
    }

    func chmod(_ path: String, mode: UInt16) async throws {}

    private func contents(of path: String) -> Data? {
        if let saved = files.withLock({ $0[path] }) { return saved }
        return Self.canned[RemotePath.lastComponent(of: path)].map { Data($0.utf8) }
    }

    private static let canned: [String: String] = [
        "contact.php": """
        <?php
        $name = trim($_POST['name'] ?? '');
        $email = trim($_POST['email'] ?? '');

        if ($name === '' || $email === '') {
            http_response_code(422);
            exit('Please fill in every field.');
        }

        $subject = "New message from " . $name
        $headers = "From: noreply@bluebirdbakery.example";

        mail('hello@bluebirdbakery.example', $subject, $_POST['message'] ?? '', $headers);
        echo 'Thanks, we will be in touch.';

        """,
        "wp-config.php": """
        <?php
        /**
         * The base configuration for WordPress.
         * Database settings come from the hosting panel.
         */

        // ** Database settings ** //
        define( 'DB_NAME', 'bluebird_wp' );
        define( 'DB_USER', 'bluebird' );
        define( 'DB_PASSWORD', 'change-me' );
        define( 'DB_HOST', 'localhost' );
        define( 'DB_CHARSET', 'utf8mb4' );
        define( 'DB_COLLATE', '' );

        /**#@+
         * Authentication unique keys and salts.
         */
        define( 'AUTH_KEY',         'put your unique phrase here' );
        define( 'SECURE_AUTH_KEY',  'put your unique phrase here' );

        $table_prefix = 'wp_';

        define( 'WP_DEBUG', false );
        define( 'WP_MEMORY_LIMIT', '256M' );

        /* That's all, stop editing! Happy publishing. */
        if ( ! defined( 'ABSPATH' ) ) {
            define( 'ABSPATH', __DIR__ . '/' );
        }

        require_once ABSPATH . 'wp-settings.php';

        """,
        "nginx.conf": """
        server {
            listen 443 ssl http2;
            server_name bluebirdbakery.example;
            root /var/www/bluebird/public;

            # Cache static assets
            location ~* \\.(css|js|png|jpg)$ {
                expires 30d;
            }
        }

        """,
    ]
}

/// Answers the editor's server commands in demo mode: tool discovery, `php -l` (a missing semicolon is the error)
/// and `nginx -t` (always fine), so the check and config-test UI can be shown with no server.
final class DemoEditorRunner: RemoteCommandRunner, @unchecked Sendable {
    static let shared = DemoEditorRunner()

    func exec(_ command: String) async throws -> SSHExecResult { SSHExecResult(exitStatus: 127) }

    func execStream(_ command: String, elevated: Bool) async throws -> AsyncThrowingStream<SSHExecEvent, Error> {
        try await execStream(command, elevated: elevated, stdin: nil)
    }

    func execStream(_ command: String, elevated: Bool, stdin: Data?) async throws -> AsyncThrowingStream<SSHExecEvent, Error> {
        var events: [SSHExecEvent] = []
        if command.contains("command -v") {
            let tools = ["php": "/usr/bin/php", "nginx": "/usr/sbin/nginx", "python3": "/usr/bin/python3", "jq": "/usr/bin/jq"]
            events = [.stdout(Data(tools.map { "tool \($0.key) \($0.value)\n" }.joined().utf8)), .exit(0)]
        } else if command.contains("nginx") && command.hasSuffix("-t") {
            events = [.stderr(Data("nginx: the configuration file /etc/nginx/nginx.conf syntax is ok\nnginx: configuration file /etc/nginx/nginx.conf test is successful\n".utf8)), .exit(0)]
        } else if command.contains("php") && command.hasSuffix("-l") {
            let lines = String(decoding: stdin ?? Data(), as: UTF8.self).components(separatedBy: "\n")
            // A statement line without a terminating `;` is a syntax error at the next code line.
            let openers: [Character] = [";", "{", "}", ",", "(", "[", ".", "*", "/"]
            if let index = lines.firstIndex(where: { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return (t.hasPrefix("$") || t.hasPrefix("echo ")) && !t.isEmpty && !openers.contains(t.last!)
            }), index + 1 < lines.count {
                var next = index + 1
                while next < lines.count - 1, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                let token = lines[next].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                let what = token.hasPrefix("$") ? "variable \"\(token)\"" : "token \"\(token)\""
                events = [.stdout(Data("\nParse error: syntax error, unexpected \(what) in Standard input code on line \(next + 1)\nErrors parsing Standard input code\n".utf8)), .exit(255)]
            } else {
                events = [.stdout(Data("No syntax errors detected in Standard input code\n".utf8)), .exit(0)]
            }
        } else {
            events = [.exit(127)]
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
