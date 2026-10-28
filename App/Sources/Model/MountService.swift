import DockyardCore
import FileProvider
import Foundation
import Observation

/// Talks to `NSFileProviderManager`. Everything here works on plain specs so no non-Sendable objects cross isolation.
enum FileProviderDomains {
    static func registered() async -> [MountDomainSpec] {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        return domains.compactMap { domain in
            let identifier = domain.identifier.rawValue
            guard let id = MountNaming.connectionId(fromDomainIdentifier: identifier) else { return nil }
            return MountDomainSpec(
                identifier: identifier, connectionId: id, displayName: domain.displayName,
                readOnly: domain.displayName.hasSuffix(MountNaming.readOnlySuffix))
        }
    }

    /// Applies the diff. A renamed domain is removed and added again, since Finder names cannot change in place.
    /// Returns the first error's description, if any.
    static func apply(_ diff: MountPolicy.DomainDiff) async -> String? {
        var firstError: String?
        func note(_ error: Error) { if firstError == nil { firstError = error.localizedDescription } }

        let existing = (try? await NSFileProviderManager.domains()) ?? []
        let removals = Set(diff.remove).union(diff.update.map(\.identifier))
        for domain in existing where removals.contains(domain.identifier.rawValue) {
            do { try await NSFileProviderManager.remove(domain) } catch { note(error) }
        }
        for spec in diff.add + diff.update {
            let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(rawValue: spec.identifier), displayName: spec.displayName)
            do { try await NSFileProviderManager.add(domain) } catch { note(error) }
        }
        return firstError
    }
}

/// Keeps the registered File Provider domains in line with the connections that have "Mount in Finder" on.
@MainActor @Observable
final class MountService {
    private(set) var lastError: String?

    @ObservationIgnored private var last: [MountDomainSpec]?
    @ObservationIgnored private var tail: Task<Void, Never>?

    /// Builds the wanted domains and, when they changed since the last call, adds and removes domains to match.
    /// Unsigned builds (CI, plain `xcodebuild`) have no extension to register, so they skip this.
    func reconcile(connections: [Connection], clientNames: [UUID: String]) {
        guard AppGroup.isSigned else { return }
        let specs = MountPolicy.desiredDomains(connections: connections, clientNames: clientNames)
        guard specs != last else { return }
        last = specs
        let previous = tail
        tail = Task {
            await previous?.value
            let registered = await FileProviderDomains.registered()
            let diff = MountPolicy.reconcile(registered: registered, connections: connections, clientNames: clientNames)
            guard !diff.isEmpty else { return }
            self.lastError = await FileProviderDomains.apply(diff)
        }
    }
}
