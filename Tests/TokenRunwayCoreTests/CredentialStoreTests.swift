import XCTest
@testable import TokenRunwayCore

final class CredentialStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        // 专用子目录：save 会 chmod 目录 0700，不能直接改共享的系统临时目录 T
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

    /// 文件 0600 / 目录 0700 是 token 文件唯一的本机保护，必须锁定：
    /// 目录已存在时（旧版本/手动创建）createDirectory 不会应用权限，save 必须强制。
    func testSaveEnforcesFileAndDirectoryPermissions() throws {
        // Arrange：先手动创建宽松权限的目录（模拟旧版本遗留），文件不存在
        let dir = tempURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int,
                       0o755 & 0o777)

        // Act：保存含 token 的配置
        var config = TokenRunwayConfigFile(providers: [:])
        config.providers["deepseek"] = ProviderCredentials(auth: "bearer", token: "sk-test")
        try CredentialStore.save(config, to: tempURL)

        // Assert：目录被强制收紧为 0700，文件为 0600
        let dirPerms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms ?? 0, 0o700, "config 目录必须 0700")
        let filePerms = try FileManager.default.attributesOfItem(atPath: tempURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(filePerms ?? 0, 0o600, "config 文件必须 0600")
    }
}
