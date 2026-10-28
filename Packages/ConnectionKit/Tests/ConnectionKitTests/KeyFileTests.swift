import Testing
@testable import ConnectionKit

@Suite struct KeyFileTests {
    @Test func publicKeyPointsAtThePrivateOne() {
        let message = SSHAuth.problem(withKey: "ssh-ed25519 AAAAC3Nz me@mac\n", path: "~/.ssh/id_ed25519.pub")
        #expect(message == "~/.ssh/id_ed25519.pub is a public key. Choose the private key (~/.ssh/id_ed25519) instead.")
        #expect(SSHAuth.problem(withKey: "ecdsa-sha2-nistp256 AAAA", path: "/k")?.contains("public key") == true)
    }

    @Test func puttyKeyIsExplained() {
        #expect(SSHAuth.problem(withKey: "PuTTY-User-Key-File-3: ssh-ed25519", path: "/k.ppk")?.contains("PuTTYgen") == true)
    }

    @Test func privateKeysPass() {
        #expect(SSHAuth.problem(withKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nb3Bl\n", path: "/k") == nil)
        #expect(SSHAuth.problem(withKey: "-----BEGIN RSA PRIVATE KEY-----\n", path: "/k") == nil)
    }
}
