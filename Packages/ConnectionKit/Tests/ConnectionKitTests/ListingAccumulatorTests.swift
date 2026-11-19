import Testing
@testable import ConnectionKit

@Suite struct ListingAccumulatorTests {
    func item(_ name: String, dir: Bool = false, link: String? = nil) -> RemoteItem {
        RemoteItem(name: name, path: "/d/" + name, isDirectory: dir, symlinkTarget: link)
    }

    @Test func keepsArrivalOrderAcrossBatches() {
        var listing = ListingAccumulator()
        listing.apply(.added([item("b"), item("a")]))
        listing.apply(.added([item("c")]))
        #expect(listing.items.map(\.name) == ["b", "a", "c"])
    }

    @Test func repeatedEntryReplacesTheFirst() {
        var listing = ListingAccumulator()
        listing.apply(.added([item("a"), item("b")]))
        listing.apply(.added([item("a", dir: true)]))
        #expect(listing.items.map(\.name) == ["a", "b"])
        #expect(listing.items[0].isDirectory)
    }

    @Test func updatesFillInKnownEntriesOnly() {
        var listing = ListingAccumulator()
        listing.apply(.added([item("link", link: ""), item("file")]))
        listing.apply(.updated([item("link", dir: true, link: "target"), item("unknown")]))
        #expect(listing.items.map(\.name) == ["link", "file"])
        #expect(listing.items[0].symlinkTarget == "target" && listing.items[0].isDirectory)
    }
}
