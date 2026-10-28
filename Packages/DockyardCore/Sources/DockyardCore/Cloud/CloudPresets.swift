import Foundation

/// The "Cloud via rclone" choices in the Quick Connect bar and site editor. Pure data; the app turns the
/// result into an rclone remote.
public struct CloudPreset: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var backend: String
    public var options: [String: String]
    /// Label for the host field (the S3 endpoint), nil when the preset has no endpoint.
    public var hostLabel: String?
    public var userLabel: String?
    public var secretLabel: String?
    public var usesOAuth: Bool

    public func spec(root: String = "", region: String? = nil) -> CloudSpec {
        var opts = options
        if let region, !region.isEmpty { opts["region"] = region }
        return CloudSpec(backend: backend, options: opts, root: root)
    }

    public static let all: [CloudPreset] = [
        CloudPreset(id: "s3", title: "Amazon S3", backend: "s3", options: ["provider": "AWS"],
                    hostLabel: nil, userLabel: "Access key ID", secretLabel: "Secret access key", usesOAuth: false),
        CloudPreset(id: "r2", title: "Cloudflare R2", backend: "s3", options: ["provider": "Cloudflare"],
                    hostLabel: "Endpoint", userLabel: "Access key ID", secretLabel: "Secret access key", usesOAuth: false),
        CloudPreset(id: "s3-other", title: "S3 compatible (MinIO, Wasabi)", backend: "s3", options: ["provider": "Other"],
                    hostLabel: "Endpoint", userLabel: "Access key ID", secretLabel: "Secret access key", usesOAuth: false),
        CloudPreset(id: "b2", title: "Backblaze B2", backend: "b2", options: [:],
                    hostLabel: nil, userLabel: "Account ID", secretLabel: "Application key", usesOAuth: false),
        CloudPreset(id: "drive", title: "Google Drive", backend: "drive", options: [:],
                    hostLabel: nil, userLabel: nil, secretLabel: nil, usesOAuth: true),
        CloudPreset(id: "dropbox", title: "Dropbox", backend: "dropbox", options: [:],
                    hostLabel: nil, userLabel: nil, secretLabel: nil, usesOAuth: true),
        CloudPreset(id: "onedrive", title: "OneDrive", backend: "onedrive", options: [:],
                    hostLabel: nil, userLabel: nil, secretLabel: nil, usesOAuth: true),
    ]

    public static func preset(id: String) -> CloudPreset? { all.first { $0.id == id } }

    /// Best match for a stored spec (used by the editor when reopening a cloud connection).
    public static func preset(for spec: CloudSpec) -> CloudPreset? {
        let candidates = all.filter { $0.backend == spec.backend }
        return candidates.first { $0.options["provider"] == spec.options["provider"] } ?? candidates.first
    }
}
