import SwiftUI
import WebKit
import TokenRunwayCore

/// 控制台登录视图（consoleSession）：内嵌 WKWebView 打开 provider 控制台，
/// 用户完成 SSO 登录后点"保存会话"，从 WebView 的 cookie 存储提取会话 cookie
/// 写入 ~/.trwy/config.json（auth=consoleSession, cookieToken/cookieUserId）。
///
/// 提取要求两个必需 cookie 都存在（如 MiMo 的 api-platform_serviceToken + userId），
/// 缺任一则提示用户先完成登录，不写入。
struct ConsoleSessionLoginView: View {
    let manifest: ProviderManifest
    var onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cookieError: String?
    @State private var isSaving = false

    private var loginURL: URL {
        URL(string: manifest.consoleURL ?? "https://platform.xiaomimimo.com")!
    }

    var body: some View {
        VStack(spacing: 12) {
            // 操作按钮放在 WebView 上方：macOS 上 WKWebView 的滚动视图可能溢出其 frame
            // 并吞掉下方内容的点击（实测 Save 在底部会被盖住点不了），头部工具栏不受影响。
            HStack {
                Text("Log in to \(manifest.displayName)")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    saveSession()
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save session")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
            Text("完成浏览器登录后，点击右上角\"Save session\"。会话过期后重新登录即可。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            WebViewRepresentable(manifestURL: loginURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if let cookieError {
                Text(cookieError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 560, height: 540)
    }

    // MARK: - Cookie extraction

    private func saveSession() {
        isSaving = true
        cookieError = nil
        Task { @MainActor in
            let cookies = await WebViewSession.cookies(for: loginURL.host ?? "")
            guard let token = cookies["api-platform_serviceToken"],
                  let userId = cookies["userId"],
                  !token.isEmpty, !userId.isEmpty else {
                cookieError = "未检测到登录会话（缺少 api-platform_serviceToken / userId cookie）。请先在页面中完成登录。"
                isSaving = false
                return
            }
            persist(token: token, userId: userId)
        }
    }

    private func persist(token: String, userId: String) {
        let url = CredentialStore.defaultURL
        var config = CredentialStore.load(from: url) ?? TokenRunwayConfigFile(providers: [:])
        config.providers[manifest.id] = ProviderCredentials(
            auth: "consoleSession",
            cookieToken: token,
            cookieUserId: userId
        )
        do {
            try CredentialStore.save(config, to: url)
            isSaving = false
            dismiss()
            onComplete()
        } catch {
            cookieError = "保存失败: \(error.localizedDescription)"
            isSaving = false
        }
    }
}

/// WKWebView 的 SwiftUI 包装（登录页本体）。
private struct WebViewRepresentable: NSViewRepresentable {
    let manifestURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WebViewSession.configuration)
        // 跟随容器尺寸变化：否则滚动视图可能溢出 frame 并吞掉下方按钮的点击
        webView.autoresizingMask = [.width, .height]
        webView.load(URLRequest(url: manifestURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// 共享 WKWebView 配置与 cookie 读取（单例 WebView，便于登录后读取同一会话的 cookie）。
/// WKWebView 类型为 MainActor-isolated，故整个枚举标注 @MainActor。
@MainActor
enum WebViewSession {
    static let configuration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        return config
    }()

    /// 读取指定 host 的 cookie（按名取值）；登录后调用。
    static func cookies(for host: String) async -> [String: String] {
        let store = configuration.websiteDataStore.httpCookieStore
        let all = await store.allCookies()
        var byName: [String: String] = [:]
        for cookie in all where cookie.domain.contains(host) || host.contains(cookie.domain) {
            byName[cookie.name] = cookie.value
        }
        return byName
    }
}
