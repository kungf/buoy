import XCTest
@testable import TokenRunwayCore

final class CredentialStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        // Dedicated subdir: save chmods the dir to 0700 and must not touch the shared system temp dir T
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trwy-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempURL = dir.appendingPathComponent("config.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func writeConfig(_ json: String) {
        try? json.data(using: .utf8)!.write(to: tempURL)
    }

    func testLoadsConfigAndMapsVolcCredential() {
        // Arrange
        writeConfig(#"{"providers":{"volcano":{"ak":"test-ak","sk":"test-sk"}}}"#)

        // Act
        let config = CredentialStore.load(from: tempURL)
        let credential = CredentialStore.credential(for: "volcano", from: config)

        // Assert
        guard case .volcAccessKey(let ak, let sk) = credential else {
            return XCTFail("expected volcAccessKey, got \(String(describing: credential))")
        }
        XCTAssertEqual(ak, "test-ak")
        XCTAssertEqual(sk, "test-sk")
    }

    func testMapsBearerToken() {
        writeConfig(#"{"providers":{"deepseek":{"token":"test-token"}}}"#)
        let credential = CredentialStore.credential(for: "deepseek", from: CredentialStore.load(from: tempURL))
        guard case .bearer(let token) = credential else {
            return XCTFail("expected bearer")
        }
        XCTAssertEqual(token, "test-token")
    }

    func testPrefersAkSkOverToken() {
        writeConfig(#"{"providers":{"volcano":{"ak":"a","sk":"s","token":"t"}}}"#)
        let credential = CredentialStore.credential(for: "volcano", from: CredentialStore.load(from: tempURL))
        guard case .volcAccessKey = credential else {
            return XCTFail("ak/sk should take precedence")
        }
    }

    func testReturnsNilForMissingOrEmpty() {
        writeConfig(#"{"providers":{"deepseek":{"token":""}}}"#)
        let config = CredentialStore.load(from: tempURL)
        XCTAssertNil(CredentialStore.credential(for: "deepseek", from: config))
        XCTAssertNil(CredentialStore.credential(for: "volcano", from: config))
        XCTAssertNil(CredentialStore.credential(for: "deepseek", from: nil))
    }

    func testLoadReturnsNilForMissingFile() {
        XCTAssertNil(CredentialStore.load(from: tempURL)) // 未写入任何文件
    }

    func testSaveRoundTrip() throws {
        // Arrange
        var config = TokenRunwayConfigFile(providers: [:])
        config.providers["deepseek"] = ProviderCredentials(auth: "bearer", token: "sk-test-token")
        config.providers["volcano"] = ProviderCredentials(auth: "volcSignature", ak: "ak-test", sk: "sk-test")

        // Act
        try CredentialStore.save(config, to: tempURL)

        // Assert — load back and verify
        let loaded = CredentialStore.load(from: tempURL)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.providers["deepseek"]?.token, "sk-test-token")
        XCTAssertEqual(loaded?.providers["deepseek"]?.auth, "bearer")
        XCTAssertEqual(loaded?.providers["volcano"]?.ak, "ak-test")
        XCTAssertEqual(loaded?.providers["volcano"]?.sk, "sk-test")
        XCTAssertEqual(loaded?.providers["volcano"]?.auth, "volcSignature")
    }

    func testSaveUpdatesExistingConfig() throws {
        // Arrange — write an initial config
        writeConfig(#"{"providers":{"deepseek":{"token":"old-token"}}}"#)

        // Act — load, modify, save
        var config = CredentialStore.load(from: tempURL)!
        config.providers["deepseek"] = ProviderCredentials(auth: "bearer", token: "new-token")
        try CredentialStore.save(config, to: tempURL)

        // Assert
        let loaded = CredentialStore.load(from: tempURL)
        XCTAssertEqual(loaded?.providers["deepseek"]?.token, "new-token")
    }

    /// File 0600 / dir 0700 are the only local protection for the token file — locked in:
    /// a pre-existing dir (old version / manual) won't pick up createDirectory permissions,
    /// so save must force them.
    func testSaveEnforcesFileAndDirectoryPermissions() throws {
        // Arrange: create a loose-permission dir first (simulating an old-version leftover); no file yet
        let dir = tempURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int,
                       0o755 & 0o777)

        // Act: save a config containing a token
        var config = TokenRunwayConfigFile(providers: [:])
        config.providers["deepseek"] = ProviderCredentials(auth: "bearer", token: "sk-test")
        try CredentialStore.save(config, to: tempURL)

        // Assert: the dir is tightened to 0700 and the file to 0600
        let dirPerms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms ?? 0, 0o700, "config dir must be 0700")
        let filePerms = try FileManager.default.attributesOfItem(atPath: tempURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(filePerms ?? 0, 0o600, "config file must be 0600")
    }
}
