import UniformTypeIdentifiers

extension UTType {
    /// The encrypted connection export (`.dockyardexport`), declared in Info.plist.
    static let dockyardExport = UTType(exportedAs: "app.dockyard.export", conformingTo: .data)
}
