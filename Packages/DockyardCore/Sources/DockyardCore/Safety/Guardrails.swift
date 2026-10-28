import Foundation

public enum OperationKind: String, Sendable, Hashable, CaseIterable {
    case download
    case upload, overwrite, delete, rename, move, mkdir, chmod, extract, compress

    /// Changes something on the server.
    public var writes: Bool { self != .download }

    /// Operations a PROD site asks about first.
    public var confirmsOnProd: Bool { self == .delete || self == .overwrite }

    public var verb: String {
        switch self {
        case .download: "download"
        case .upload: "upload"
        case .overwrite: "overwrite"
        case .delete: "delete"
        case .rename: "rename"
        case .move: "move"
        case .mkdir: "create a folder in"
        case .chmod: "change permissions on"
        case .extract: "extract an archive into"
        case .compress: "compress files on"
        }
    }
}

/// What a user is about to do, for guardrail decisions.
public struct GuardedOperation: Sendable, Equatable {
    public var kind: OperationKind
    /// Remote paths that will change.
    public var paths: [String]

    public init(_ kind: OperationKind, paths: [String] = []) {
        self.kind = kind
        self.paths = paths
    }
}

public struct ConfirmationSummary: Sendable, Equatable {
    public var kind: OperationKind
    public var title: String
    /// At most `Guardrails.listLimit` paths, for display.
    public var items: [String]
    public var totalCount: Int
    /// The caller may offer "Don't ask again for this session" for this kind.
    public var canSuppressForSession: Bool

    public var hiddenCount: Int { max(0, totalCount - items.count) }
}

public enum GuardrailDecision: Sendable, Equatable {
    case allow
    case confirm(ConfirmationSummary)
    case deny(reason: String)
}

/// Decides whether an operation on a connection runs, needs a confirmation, or is refused. Pure.
public enum Guardrails {
    public static let listLimit = 10

    /// `suppressed` holds the kinds the user chose not to be asked about again in this session.
    /// Read-only is never suppressible.
    public static func decide(
        _ operation: GuardedOperation,
        isProd: Bool,
        readOnly: Bool,
        connectionName: String? = nil,
        suppressed: Set<OperationKind> = []
    ) -> GuardrailDecision {
        let kind = operation.kind
        if readOnly, kind.writes {
            let site = connectionName.map { "\"\($0)\"" } ?? "This site"
            return .deny(reason: "\(site) is read-only, so Dockyard will not \(kind.verb) it. Turn off Read-only in the site settings to allow changes.")
        }
        guard isProd, kind.confirmsOnProd, !suppressed.contains(kind) else { return .allow }

        let total = operation.paths.count
        let noun = total == 1 ? "1 item" : "\(total) items"
        let title: String
        switch kind {
        case .delete: title = total == 0 ? "Delete on a PROD site?" : "Delete \(noun) on a PROD site?"
        default: title = total == 0 ? "Overwrite on a PROD site?" : "Overwrite \(noun) on a PROD site?"
        }
        return .confirm(ConfirmationSummary(
            kind: kind, title: title, items: Array(operation.paths.prefix(listLimit)),
            totalCount: total, canSuppressForSession: true
        ))
    }

    public static func decide(
        _ operation: GuardedOperation,
        for connection: Connection,
        suppressed: Set<OperationKind> = []
    ) -> GuardrailDecision {
        decide(operation, isProd: connection.isProd, readOnly: connection.readOnly,
               connectionName: connection.name, suppressed: suppressed)
    }
}
