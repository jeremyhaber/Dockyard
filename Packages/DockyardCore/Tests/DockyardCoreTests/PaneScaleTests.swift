import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct PaneScaleTests {
    @Test func tenThousandFilesSortAndCount() {
        let items = (0..<10_000).map { i in
            RemoteItem(name: "file\((i * 7919) % 10_000).dat", path: "/big/f\(i)", isDirectory: i % 50 == 0, size: UInt64(i), modified: Date(timeIntervalSince1970: Double(i)))
        }
        let start = Date()
        for key in SortKey.allCases { _ = FileListModel.rows(for: items, at: "/big", sort: FileSort(key: key, ascending: false)) }
        #expect(Date().timeIntervalSince(start) < 5)
        let rows = FileListModel.rows(for: items, at: "/big")
        #expect(rows.count == 10_001)
        #expect(FileListModel.footer(for: items) == "9800 files, 200 folders")
    }
}
