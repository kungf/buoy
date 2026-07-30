import XCTest
@testable import TokenRunwayCore

final class CredentialStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trwy-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
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
}
