import SwiftUI
import TokenRunwayCore

/// Credential settings sheet for a single provider. Renders provider-specific
/// auth form fields (bearer token or volc AK/SK) and writes to ~/.trwy/config.json.
struct ProviderSettingsView: View {
    @ObservedObject var store: UsageStore
    let manifest: ProviderManifest

    /// Auth mode drives the form shape; sourced from the manifest.
    private var authMode: AuthMode { manifest.authMode }

    @Environment(\.dismiss) private var dismiss

    @State private var token: String = ""
    @State private var ak: String = ""
    @State private var sk: String = ""
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var showHelp = false
    @State private var showToken = false
    @State private var showSK = false
    @State private var showLogin = false
    @State private var hasSession = false

    private var displayName: String {
        store.providerDisplayName(for: manifest.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 10) {
                ProviderTheme.theme(for: manifest.id).makeImage()
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 18)
                Text("Configure \(displayName)")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Form fields — provider-specific
            switch authMode {
            case .bearer:
                bearerFields
            case .volcSignature:
                volcFields
            case .consoleSession:
                consoleSessionFields
            case .localCLI:
                localCLIFields
            }

            // Error
            if let error = saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: save) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || isSaving)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { loadExisting() }
    }

    // MARK: - Bearer token (DeepSeek)

    private var bearerFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API Token").font(.caption.weight(.medium))
            HStack(spacing: 4) {
                Group {
                    if showToken {
                        TextField("sk-...", text: $token)
                    } else {
                        SecureField("sk-...", text: $token)
                    }
                }
                .textFieldStyle(.roundedBorder)
                Button { showToken.toggle() } label: {
                    Image(systemName: showToken ? "eye" : "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(showToken ? "Hide token" : "Show token")
            }
            HStack(spacing: 4) {
                Text("Paste your API token from the \(displayName) console.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                helpButton
            }
        }
    }

    // MARK: - Volc IAM AK/SK (Volcano)

    private var volcFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Access Key (AK)").font(.caption.weight(.medium))
                TextField("AKLT...", text: $ak)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Secret Key (SK)").font(.caption.weight(.medium))
                HStack(spacing: 4) {
                    Group {
                        if showSK {
                            TextField("...", text: $sk)
                        } else {
                            SecureField("...", text: $sk)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button { showSK.toggle() } label: {
                        Image(systemName: showSK ? "eye" : "eye.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(showSK ? "Hide secret key" : "Show secret key")
                }
            }
            HStack(spacing: 4) {
                Text("Create an IAM access key from the Volcano Ark console.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                helpButton
            }
        }
    }

    // MARK: - consoleSession (MiMo)：内嵌 WebView 登录，会话 cookie 自维护

    private var consoleSessionFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hasSession ? "已登录。会话过期后重新登录即可。" : "未登录——点击\"Login\"在内嵌浏览器中完成登录。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Login…") { showLogin = true }
                if hasSession {
                    Button("Clear session") { clearSession() }
                        .foregroundStyle(.red)
                }
            }
            HStack(spacing: 4) {
                Text("会话 cookie 由本应用维护，过期后自动提示重新登录。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                helpButton
            }
        }
        .sheet(isPresented: $showLogin) {
            ConsoleSessionLoginView(manifest: manifest) {
                hasSession = true
                Task { await store.refresh() }
            }
        }
    }

    private func clearSession() {
        let url = CredentialStore.defaultURL
        var config = CredentialStore.load(from: url) ?? TokenRunwayConfigFile(providers: [:])
        config.providers.removeValue(forKey: manifest.id)
        do {
            try CredentialStore.save(config, to: url)
            hasSession = false
            saveError = nil
            Task { await store.refresh() }
        } catch {
            saveError = "Failed to clear session: \(error.localizedDescription)"
        }
    }

    // MARK: - localCLI (Kimi Code)：无需输入，自动复用本机 CLI 登录态

    private var localCLIFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No token needed — \(displayName) automatically reuses the local Kimi Code CLI login (~/.kimi-code).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text("Not logged in? Run `kimi` and execute /login first.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                helpButton
            }
        }
    }

    // MARK: - Help

    private var helpButton: some View {
        Button {
            showHelp = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showHelp, arrowEdge: .bottom) {
            helpContent
                .padding(14)
                .frame(width: 300)
        }
    }

    @ViewBuilder
    private var helpContent: some View {
        switch authMode {
        case .bearer:
            VStack(alignment: .leading, spacing: 8) {
                Text("How to get your API token")
                    .font(.subheadline.weight(.semibold))
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Open \(displayName) Platform")
                    Text(manifest.consoleURL ?? "-")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.blue)
                        .padding(.leading, 20)
                    step(2, "Click \"API Keys\" in the left sidebar")
                    step(3, "Click \"Create new key\", name it, copy the token")
                    step(4, "Paste the token above and save")
                }
            }
        case .volcSignature:
            VStack(alignment: .leading, spacing: 8) {
                Text("How to create your AK/SK")
                    .font(.subheadline.weight(.semibold))
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Open Volcano Ark Console")
                    Text(manifest.consoleURL ?? "-")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.blue)
                        .padding(.leading, 20)
                    step(2, "Click your avatar in the top-right corner")
                    step(3, "Select \"API Access Key\" (API 访问密钥)")
                    step(4, "Click \"Create New Key\" (新建密钥)")
                    step(5, "Copy the AK and SK, paste above and save")
                }
            }
        case .consoleSession:
            VStack(alignment: .leading, spacing: 8) {
                Text("How console login works")
                    .font(.subheadline.weight(.semibold))
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Click \"Login…\" — an embedded browser opens \(displayName) console")
                    step(2, "Sign in with your Xiaomi account")
                    step(3, "Click \"Save session\" to store the login cookies")
                    step(4, "When the session expires, log in again here")
                }
            }
        case .localCLI:
            VStack(alignment: .leading, spacing: 8) {
                Text("How \(displayName) auth works")
                    .font(.subheadline.weight(.semibold))
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Install and run the `kimi` CLI on this Mac")
                    step(2, "Inside the CLI, run /login and finish sign-in")
                    step(3, "Come back — no token input is needed here")
                }
                Text("Quota details: \(manifest.consoleURL ?? "-")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func step(_ num: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(num).")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.caption2)
        }
    }

    // MARK: - Logic

    private var canSave: Bool {
        switch authMode {
        case .bearer: return !token.trimmingCharacters(in: .whitespaces).isEmpty
        case .volcSignature: return !ak.trimmingCharacters(in: .whitespaces).isEmpty
            && !sk.trimmingCharacters(in: .whitespaces).isEmpty
        case .consoleSession: return false
        case .localCLI: return false   // 无需填写，直接关闭即可
        }
    }

    private func loadExisting() {
        let config = CredentialStore.load()
        switch authMode {
        case .bearer:
            token = config?.providers[manifest.id]?.token ?? ""
        case .volcSignature:
            ak = config?.providers[manifest.id]?.ak ?? ""
            sk = config?.providers[manifest.id]?.sk ?? ""
        case .consoleSession:
            let entry = config?.providers[manifest.id]
            hasSession = !(entry?.cookieToken ?? "").isEmpty && !(entry?.cookieUserId ?? "").isEmpty
        case .localCLI:
            break
        }
    }

    private func save() {
        isSaving = true
        saveError = nil
        let url = CredentialStore.defaultURL
        var config = CredentialStore.load(from: url) ?? TokenRunwayConfigFile(providers: [:])

        var entry = config.providers[manifest.id] ?? ProviderCredentials()
        switch authMode {
        case .bearer:
            entry.auth = "bearer"
            entry.token = token.trimmingCharacters(in: .whitespaces)
        case .volcSignature:
            entry.auth = "volcSignature"
            entry.ak = ak.trimmingCharacters(in: .whitespaces)
            entry.sk = sk.trimmingCharacters(in: .whitespaces)
        case .consoleSession:
            break
        case .localCLI:
            break   // 不写 config.json：登录态在本机 CLI 凭证文件里
        }
        config.providers[manifest.id] = entry

        do {
            try CredentialStore.save(config, to: url)
            isSaving = false
            dismiss()
            Task { await store.refresh() }
        } catch {
            saveError = "Failed to save: \(error.localizedDescription)"
            isSaving = false
        }
    }
}
