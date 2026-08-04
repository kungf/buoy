import XCTest
@testable import TokenRunwayCore

/// CustomMetricConfigStore：自定义指标配置在 ~/.trwy/config.json 的增删查
/// （与 providers 同文件原子写回，保证 trwyctl 与 App 共享）。
final class CustomMetricConfigStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        // 专用子目录：save 会 chmod 目录 0700，不能直接改共享的系统临时目录 T
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

    /// 旧 config.json（无 customMetrics 字段）仍可解码，不破坏现有用户
    func testLoadFromLegacyFileWithoutCustomMetrics() {
        // Arrange
        try? #"{"providers":{"deepseek":{"token":"t"}}}"#.data(using: .utf8)!.write(to: tempURL)

        // Act / Assert
        XCTAssertEqual(CustomMetricConfigStore.load(from: tempURL), [])
        // 且 providers 未被破坏
        let config = CredentialStore.load(from: tempURL)
        XCTAssertEqual(config?.providers["deepseek"]?.token, "t")
    }

    func testUpsertAddsAndReplacesById() throws {
        // Arrange
        try CustomMetricConfigStore.upsert(makeConfig(id: "custom-1"), to: tempURL)
        try CustomMetricConfigStore.upsert(makeConfig(id: "custom-2"), to: tempURL)

        // Act：替换 custom-1（改 name），不新增
        var updated = makeConfig(id: "custom-1")
        updated.name = "新预算"
        try CustomMetricConfigStore.upsert(updated, to: tempURL)

        // Assert
        let configs = CustomMetricConfigStore.load(from: tempURL)
        XCTAssertEqual(configs.map(\.id), ["custom-1", "custom-2"])
        XCTAssertEqual(configs.first { $0.id == "custom-1" }?.name, "新预算")
    }

    /// upsert 不破坏同文件的 providers 条目（token 等）
    func testUpsertPreservesProviders() throws {
        // Arrange：先有 providers 条目
        var file = TokenRunwayConfigFile(providers: ["deepseek": ProviderCredentials(token: "t")])
        try CredentialStore.save(file, to: tempURL)

        // Act
        try CustomMetricConfigStore.upsert(makeConfig(id: "custom-1"), to: tempURL)

        // Assert
        let saved = CredentialStore.load(from: tempURL)
        XCTAssertEqual(saved?.providers["deepseek"]?.token, "t")
        XCTAssertEqual(saved?.customMetrics.map(\.id), ["custom-1"])
    }

    /// remove 同时清理同 id 的凭证条目（providers[<id>].token）
    func testRemoveCleansConfigAndCredential() throws {
        // Arrange
        try CustomMetricConfigStore.upsert(makeConfig(id: "custom-1"), to: tempURL)
        var file = CredentialStore.load(from: tempURL)!
        file.providers["custom-1"] = ProviderCredentials(auth: "bearer", token: "sekret")
        try CredentialStore.save(file, to: tempURL)

        // Act
        try CustomMetricConfigStore.remove(id: "custom-1", from: tempURL)

        // Assert：配置与凭证一并删除
        let saved = CredentialStore.load(from: tempURL)
        XCTAssertEqual(saved?.customMetrics, [])
        XCTAssertNil(saved?.providers["custom-1"])
    }
}
