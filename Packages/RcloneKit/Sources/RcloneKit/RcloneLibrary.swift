import CRclone
import ConnectionKit
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct RcloneResponse: Sendable, Equatable {
    public var status: Int
    public var output: String

    public init(status: Int, output: String) {
        self.status = status
        self.output = output
    }
}

/// Anything that can execute an rc call. `RcloneLibrary` is the real one; tests substitute a fake.
public protocol RcloneTransport: Sendable {
    func perform(method: String, input: String) async -> RcloneResponse
}

public enum RcloneLibraryError: Error, Equatable, CustomStringConvertible {
    case notFound
    case loadFailed(String)
    case missingSymbol(String)

    public var description: String {
        switch self {
        case .notFound: "librclone was not found"
        case .loadFailed(let m): "Could not load librclone: \(m)"
        case .missingSymbol(let s): "librclone is missing symbol \(s)"
        }
    }
}

/// A librclone loaded with `dlopen`, so nothing links against it at build time.
public final class RcloneLibrary: RcloneTransport, @unchecked Sendable {
    public static let environmentVariable = "DOCKYARD_LIBRCLONE"

    private static let loaded = LockedBox<[String: RcloneLibrary]>([:])

    public let path: String
    private let rpc: RcloneRPCFn
    private let freeString: RcloneFreeStringFn

    private init(path: String) throws {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw RcloneLibraryError.loadFailed(String(cString: dlerror()))
        }
        func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
            guard let p = dlsym(handle, name) else { throw RcloneLibraryError.missingSymbol(name) }
            return p
        }
        let initialize = unsafeBitCast(try symbol("RcloneInitialize"), to: RcloneInitializeFn.self)
        rpc = unsafeBitCast(try symbol("RcloneRPC"), to: RcloneRPCFn.self)
        freeString = unsafeBitCast(try symbol("RcloneFreeString"), to: RcloneFreeStringFn.self)
        self.path = path
        initialize()
    }

    /// Loads the library at `path` once per process.
    public static func load(path: String) throws -> RcloneLibrary {
        try loaded.withLock { cache in
            if let existing = cache[path] { return existing }
            let library = try RcloneLibrary(path: path)
            cache[path] = library
            return library
        }
    }

    /// Loads from `explicit`, `$DOCKYARD_LIBRCLONE`, or the app bundle's Frameworks folder (also from inside an app extension).
    public static func load(explicit: String? = nil) throws -> RcloneLibrary {
        guard let found = locate(explicit: explicit) else { throw RcloneLibraryError.notFound }
        return try load(path: found)
    }

    public static func locate(explicit: String? = nil) -> String? {
        var candidates: [String] = []
        if let explicit { candidates.append(explicit) }
        if let env = ProcessInfo.processInfo.environment[environmentVariable], !env.isEmpty { candidates.append(env) }
        var folders: [URL] = []
        if let frameworks = Bundle.main.privateFrameworksURL { folders.append(frameworks) }
        // App extension: App.app/Contents/PlugIns/X.appex -> App.app/Contents/Frameworks.
        let appexParent = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        folders.append(appexParent.appendingPathComponent("Frameworks"))
        for folder in folders {
            for name in ["librclone.dylib", "librclone.so"] {
                candidates.append(folder.appendingPathComponent(name).path)
            }
        }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    public func perform(method: String, input: String) async -> RcloneResponse {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.performBlocking(method: method, input: input))
            }
        }
    }

    private func performBlocking(method: String, input: String) -> RcloneResponse {
        guard let m = strdup(method), let i = strdup(input) else {
            return RcloneResponse(status: 500, output: #"{"error":"out of memory"}"#)
        }
        defer { free(m); free(i) }
        let result = rpc(m, i)
        defer { if let out = result.Output { freeString(out) } }
        let output = result.Output.map { String(cString: $0) } ?? ""
        return RcloneResponse(status: Int(result.Status), output: output)
    }
}
