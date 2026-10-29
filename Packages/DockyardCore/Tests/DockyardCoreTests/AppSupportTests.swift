import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct AppSupportTests {
    @Test func knownHostTrustOnFirstUse() async throws {
        let repo = KnownHostRepository(database: try DockyardDatabase())
        #expect(try await repo.verdict(host: "Box.Example.com", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:aaa") == .unknown)
        try await repo.trust(host: "box.example.com", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:aaa")
        #expect(try await repo.verdict(host: "BOX.example.com", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:aaa") == .trusted)
        #expect(try await repo.verdict(host: "box.example.com", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:bbb") == .changed(previous: "SHA256:aaa"))
        #expect(try await repo.verdict(host: "box.example.com", port: 2222, keyType: "ssh-ed25519", fingerprint: "SHA256:aaa") == .unknown)
        try await repo.trust(host: "box.example.com", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:bbb")
        #expect(try await repo.verdict(host: "box.example.com", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:bbb") == .trusted)
        try await repo.forget(host: "box.example.com", port: 22)
        #expect(try await repo.count() == 0)
    }

    @Test func connectionKeepsLocalFolderAndCloudSpec() async throws {
        let repo = ConnectionRepository(database: try DockyardDatabase())
        let spec = CloudSpec(backend: "s3", options: ["provider": "Minio", "region": "eu"], root: "bucket/site")
        let c = Connection(name: "R2", protocol: .rclone, host: "https://x.r2.example", username: "AK",
                           localFolder: "/Users/me/Sites", cloud: spec)
        try await repo.save(c)
        let loaded = try #require(try await repo.connection(id: c.id))
        #expect(loaded.localFolder == "/Users/me/Sites")
        #expect(loaded.cloud == spec)
        let plain = Connection(name: "Plain", host: "h", username: "u")
        try await repo.save(plain)
        let p = try #require(try await repo.connection(id: plain.id))
        #expect(p.cloud == nil && p.localFolder == nil)
        #expect(p.localStart == .defaultFolder && !p.localStartOverridesRestore)
    }

    @Test func connectionKeepsLocalStart() async throws {
        let repo = ConnectionRepository(database: try DockyardDatabase())
        let c = Connection(name: "S", host: "h", username: "u", localStart: .scratch, localStartOverridesRestore: true)
        try await repo.save(c)
        let loaded = try #require(try await repo.connection(id: c.id))
        #expect(loaded.localStart == .scratch && loaded.localStartOverridesRestore)
    }

    @Test func cloudPresets() {
        #expect(CloudPreset.preset(id: "r2")?.spec(root: "b", region: "auto").options == ["provider": "Cloudflare", "region": "auto"])
        let spec = CloudSpec(backend: "s3", options: ["provider": "Other"])
        #expect(CloudPreset.preset(for: spec)?.id == "s3-other")
        #expect(spec.listsBuckets)
        #expect(!CloudSpec(backend: "s3", root: "bucket").listsBuckets)
        #expect(!CloudSpec(backend: "drive").listsBuckets)
    }

    @Test func fileDisplay() {
        #expect(FileDisplay.size(nil) == "")
        #expect(FileDisplay.size(512) == "512 B")
        #expect(FileDisplay.size(1536) == "1.5 KB")
        #expect(FileDisplay.size(25 * 1024 * 1024) == "25 MB")
        #expect(FileDisplay.permissions(0o755) == "rwxr-xr-x")
        #expect(FileDisplay.permissions(0o4755) == "rwsr-xr-x")
        #expect(FileDisplay.permissions(0o1777) == "rwxrwxrwt")
        #expect(FileDisplay.octal(0o644) == "644")
        #expect(FileDisplay.parseOctal("0755") == 0o755)
        #expect(FileDisplay.parseOctal("789") == nil)
        #expect(FileDisplay.parseOctal("") == nil)
    }

    @Test func compactModifiedDate() {
        let utc = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_792_929_600)  // 2026-10-25 12:00 UTC
        let sameYearOffset: TimeInterval = -3 * 86_400 + 2 * 3_600 + 120
        let sameYear = now.addingTimeInterval(sameYearOffset)
        #expect(FileDisplay.modifiedCompact(nil, now: now, timeZone: utc) == "")
        #expect(FileDisplay.modifiedCompact(now, now: now, timeZone: utc) == "Oct 25, 12:00")
        #expect(FileDisplay.modifiedCompact(sameYear, now: now, timeZone: utc) == "Oct 22, 14:02")
        let earlier = Date(timeIntervalSince1970: 1_792_929_600 - 400 * 86_400)
        #expect(FileDisplay.modifiedCompact(earlier, now: now, timeZone: utc) == "Sep 20, 2025")
    }

    @Test func dropPlanning() {
        let dir = RemoteItem(name: "a", path: "/x/a", isDirectory: true)
        let file = RemoteItem(name: "f", path: "/x/f", isDirectory: false)
        #expect(DropPlanner.plan(items: [file], destinationDirectory: "/x/a", sameFileSystem: true, optionKey: false) == .move)
        #expect(DropPlanner.plan(items: [file], destinationDirectory: "/x/a", sameFileSystem: true, optionKey: true) == .copy)
        #expect(DropPlanner.plan(items: [dir], destinationDirectory: "/x/a/b", sameFileSystem: true, optionKey: false) == .reject)
        #expect(DropPlanner.plan(items: [dir], destinationDirectory: "/x/a", sameFileSystem: true, optionKey: false) == .reject)
        #expect(DropPlanner.plan(items: [file], destinationDirectory: "/x", sameFileSystem: true, optionKey: false) == .reject)
        #expect(DropPlanner.plan(items: [file], destinationDirectory: "/x", sameFileSystem: false, optionKey: false) == .copy)
        #expect(DropPlanner.plan(items: [], destinationDirectory: "/x", sameFileSystem: false, optionKey: false) == .reject)
    }
}
