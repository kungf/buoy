import XCTest
@testable import TokenRunwayCore

/// CustomMetricConfigStore: custom-metric config add/query/remove in ~/.trwy/config.json
/// (same file as providers, atomic write-back, shared by trwyctl and the App).
final class CustomMetricConfigStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        // Dedicated subdir: save chmods the dir to 0700 and must not touch the shared system temp dir T
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trwy-custom-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempURL = dir.appendingPathComponent("config.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeConfig(id: String) -> CustomMetricConfig {
        CustomMetricConfig(id: id, name: "预算", baseURL: "http://prom:9090", metric: "usage")
    }

    func testLoadReturnsEmptyWhenFileMissing() {
        // Act / Assert
        XCTAssertEqual(CustomMetricConfigStore.load(from: tempURL), [])
    }

    /// Legacy config.json (no customMetrics field) still decodes — existing users unaffected
    func testLoadFromLegacyFileWithoutCustomMetrics() {
        // Arrange
        try? #"{"providers":{"deepseek":{"token":"t"}}}"#.data(using: .utf8)!.write(to: tempURL)

        // Act / Assert
        XCTAssertEqual(CustomMetricConfigStore.load(from: tempURL), [])
        // and providers are untouched
        let config = CredentialStore.load(from: tempURL)
        XCTAssertEqual(config?.providers["deepseek"]?.token, "t")
    }

    func testUpsertAddsAndReplacesById() throws {
        // Arrange
        try CustomMetricConfigStore.upsert(makeConfig(id: "custom-1"), to: tempURL)
        try CustomMetricConfigStore.upsert(makeConfig(id: "custom-2"), to: tempURL)

        // Act: replace custom-1 (rename), no new entry
        var updated = makeConfig(id: "custom-1")
        updated.name = "新预算"
        try CustomMetricConfigStore.upsert(updated, to: tempURL)

        // Assert
        let configs = CustomMetricConfigStore.load(from: tempURL)
        XCTAssertEqual(configs.map(\.id), ["custom-1", "custom-2"])
        XCTAssertEqual(configs.first { $0.id == "custom-1" }?.name, "新预算")
    }

    /// upsert leaves same-file providers entries (tokens etc.) intact
    func testUpsertPreservesProviders() throws {
        // Arrange: a providers entry exists first
        var file = TokenRunwayConfigFile(providers: ["deepseek": ProviderCredentials(token: "t")])
        try CredentialStore.save(file, to: tempURL)

        // Act
        try CustomMetricConfigStore.upsert(makeConfig(id: "custom-1"), to: tempURL)

        // Assert
        let saved = CredentialStore.load(from: tempURL)
        XCTAssertEqual(saved?.providers["deepseek"]?.token, "t")
        XCTAssertEqual(saved?.customMetrics.map(\.id), ["custom-1"])
    }

    /// remove also cleans the same-id credential entry (providers[<id>].token)
    func testRemoveCleansConfigAndCredential() throws {
        // Arrange
        try CustomMetricConfigStore.upsert(makeConfig(id: "custom-1"), to: tempURL)
        var file = CredentialStore.load(from: tempURL)!
        file.providers["custom-1"] = ProviderCredentials(auth: "bearer", token: "sekret")
        try CredentialStore.save(file, to: tempURL)

        // Act
        try CustomMetricConfigStore.remove(id: "custom-1", from: tempURL)

        // Assert: config and credential are both removed
        let saved = CredentialStore.load(from: tempURL)
        XCTAssertEqual(saved?.customMetrics, [])
        XCTAssertNil(saved?.providers["custom-1"])
    }
}
