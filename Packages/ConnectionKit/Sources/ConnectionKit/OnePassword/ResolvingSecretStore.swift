import Foundation

/// Turns a secret reference such as `op://Vault/Item/password` into the secret.
public protocol SecretReferenceResolving: Sendable {
    func resolve(reference: String) async throws -> String
}

/// Where a connection keeps its secret references. References are not secrets, but they stay out of logs.
public protocol SecretReferenceSource: Sendable {
    func reference(for connection: UUID, purpose: SecretPurpose) async -> String?
}

/// A fixed set of references, for tests and previews.
public struct StaticSecretReferences: SecretReferenceSource {
    private let references: [UUID: [SecretPurpose: String]]

    public init(_ references: [UUID: [SecretPurpose: String]] = [:]) { self.references = references }

    public func reference(for connection: UUID, purpose: SecretPurpose) async -> String? { references[connection]?[purpose] }
}

/// Reads a connection's secret from its reference when it has one, otherwise from `fallback` (the Keychain).
/// Writes and removals go to `fallback`: a reference is changed by editing the connection, not through this store.
/// With a cache TTL above zero, resolved values stay in memory for that long as bytes that are zeroed on expiry.
public actor ResolvingSecretStore: SecretStore {
    public struct Options: Sendable {
        /// Seconds a resolved secret is reused. 0 resolves on every call.
        public var cacheTTL: TimeInterval
        /// When resolving fails, use the fallback store's value if it has one instead of throwing.
        public var fallbackOnFailure: Bool

        public init(cacheTTL: TimeInterval = 0, fallbackOnFailure: Bool = true) {
            self.cacheTTL = cacheTTL
            self.fallbackOnFailure = fallbackOnFailure
        }
    }

    private struct CacheEntry {
        var bytes: [UInt8]
        var expires: Date
    }

    private let fallback: any SecretStore
    private let references: any SecretReferenceSource
    private let resolver: any SecretReferenceResolving
    private let options: Options
    private let now: @Sendable () -> Date
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<String, Error>] = [:]

    public init(
        fallback: any SecretStore, references: any SecretReferenceSource, resolver: any SecretReferenceResolving,
        options: Options = Options(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fallback = fallback
        self.references = references
        self.resolver = resolver
        self.options = options
        self.now = now
    }

    deinit {
        for key in cache.keys { Self.zero(&cache[key]!.bytes) }
    }

    public func secret(for connection: UUID, purpose: SecretPurpose) async throws -> String? {
        guard let reference = await references.reference(for: connection, purpose: purpose) else {
            return try await fallback.secret(for: connection, purpose: purpose)
        }
        do {
            return try await resolve(reference)
        } catch {
            if options.fallbackOnFailure, let stored = try await fallback.secret(for: connection, purpose: purpose) { return stored }
            throw error
        }
    }

    public func setSecret(_ secret: String, for connection: UUID, purpose: SecretPurpose) async throws {
        try await fallback.setSecret(secret, for: connection, purpose: purpose)
    }

    public func removeSecret(for connection: UUID, purpose: SecretPurpose) async throws {
        try await fallback.removeSecret(for: connection, purpose: purpose)
    }

    /// Forgets every cached secret (call when the app locks or a connection is edited).
    public func flushCache() {
        for key in cache.keys { Self.zero(&cache[key]!.bytes) }
        cache.removeAll()
    }

    private func resolve(_ reference: String) async throws -> String {
        if options.cacheTTL > 0 {
            if var entry = cache[reference] {
                if entry.expires > now() { return String(decoding: entry.bytes, as: UTF8.self) }
                Self.zero(&entry.bytes)
                cache[reference] = nil
            }
            // Concurrent connections to one site share a single `op read` (and a single authorization prompt).
            if let task = inFlight[reference] { return try await task.value }
        }
        let resolver = resolver
        let task = Task { try await resolver.resolve(reference: reference) }
        if options.cacheTTL > 0 { inFlight[reference] = task }
        defer { inFlight[reference] = nil }
        let value = try await task.value
        if options.cacheTTL > 0 {
            cache[reference] = CacheEntry(bytes: Array(value.utf8), expires: now().addingTimeInterval(options.cacheTTL))
        }
        return value
    }

    private static func zero(_ bytes: inout [UInt8]) {
        for index in bytes.indices { bytes[index] = 0 }
    }
}
