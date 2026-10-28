import ConnectionKit
import Foundation

/// Lets `ResolvingSecretStore` look up each connection's secret references in the database.
extension ConnectionRepository: SecretReferenceSource {
    public func reference(for connection: UUID, purpose: SecretPurpose) async -> String? {
        (try? await self.connection(id: connection))?.secretReferences[purpose]
    }
}
