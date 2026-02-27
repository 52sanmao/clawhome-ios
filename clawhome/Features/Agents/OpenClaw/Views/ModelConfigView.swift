//
//  ModelConfigView.swift
//  contextgo
//
//  OpenClaw 模型配置视图 - 显示通过 config.get RPC 获取的模型配置
//

import SwiftUI

struct ModelConfigView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var viewModel: ModelConfigViewModel

    // Edit states
    @State private var showEditProvider: String? = nil
    @State private var showModeSelector = false

    init(client: OpenClawClient) {
        _viewModel = StateObject(wrappedValue: ModelConfigViewModel(client: client))
    }

    var body: some View {
        NavigationView {
            ZStack {
                // Background
                (colorScheme == .dark ? Color.black : Color(.systemGroupedBackground))
                    .ignoresSafeArea()

                if viewModel.isLoading {
                    ProgressView("加载中...")
                        .tint(.blue)
                } else if let error = viewModel.errorMessage {
                    errorView(error)
                } else if let config = viewModel.modelConfig {
                    contentView(config)
                }
            }
            .navigationTitle("模型配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") {
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        Task { await viewModel.loadConfig() }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .disabled(viewModel.isLoading)
                }
            }
        }
        .task {
            await viewModel.loadConfig()
        }
        .sheet(item: $showEditProvider) { providerName in
            if let provider = viewModel.modelConfig?.providers?[providerName] {
                EditProviderSheet(
                    providerName: providerName,
                    provider: provider,
                    onSave: { newApiKey, newBaseUrl in
                        Task {
                            await viewModel.updateProvider(name: providerName, apiKey: newApiKey, baseUrl: newBaseUrl)
                        }
                    }
                )
            }
        }
        .confirmationDialog("选择模式", isPresented: $showModeSelector) {
            Button("Merge (合并默认配置)") {
                Task { await viewModel.updateMode("merge") }
            }
            Button("Replace (替换默认配置)") {
                        Task { await viewModel.updateMode("override") }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("选择模型配置模式")
        }
    }

    // MARK: - Content View

    @ViewBuilder
    private func contentView(_ config: ModelConfigData) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                // 配置文件信息卡片
                configInfoCard(config)

                // Providers 列表
                if let providers = config.providers {
                    providersListCard(providers)
                }
            }
            .padding()
        }
    }

    // MARK: - Config Info Card

    @ViewBuilder
    private func configInfoCard(_ config: ModelConfigData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .foregroundColor(.blue)
                Text("配置文件")
                    .font(.headline)
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
            }

            VStack(alignment: .leading, spacing: 12) {
                // 文件路径
                if let path = config.path {
                    HStack(alignment: .top, spacing: 8) {
                        Text("路径:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(colorScheme == .dark ? .white : .primary)
                            .lineLimit(nil)
                            .textSelection(.enabled)
                    }
                }

                // 文件存在状态
                HStack(spacing: 8) {
                    Text("状态:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .leading)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(config.exists ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(config.exists ? "已加载" : "未找到")
                            .font(.subheadline)
                            .foregroundColor(config.exists ? .green : .red)
                    }
                }

                // 配置有效性
                if let valid = config.valid {
                    HStack(spacing: 8) {
                        Text("有效:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)
                        HStack(spacing: 6) {
                            Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(valid ? .green : .red)
                            Text(valid ? "是" : "否")
                                .font(.subheadline)
                                .foregroundColor(valid ? .green : .red)
                        }
                    }
                }

                // 模式
                if let mode = config.mode {
                    HStack(spacing: 8) {
                        Text("模式:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)

                        Button(action: {
                            showModeSelector = true
                        }) {
                            HStack(spacing: 4) {
                                Text(mode)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundColor(.blue)
                                Image(systemName: "chevron.down.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(cardBackground)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    // MARK: - Providers List Card

    @ViewBuilder
    private func providersListCard(_ providers: [String: ProviderConfig]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "cpu.fill")
                    .foregroundColor(.purple)
                Text("模型提供商")
                    .font(.headline)
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
                Spacer()
                Text("\(providers.count) 个")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 12) {
                ForEach(Array(providers.keys.sorted()), id: \.self) { providerName in
                    if let provider = providers[providerName] {
                        providerRow(name: providerName, provider: provider)
                    }
                }
            }
        }
        .padding()
        .background(cardBackground)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    @ViewBuilder
    private func providerRow(name: String, provider: ProviderConfig) -> some View {
        Button(action: {
            showEditProvider = name
        }) {
            VStack(alignment: .leading, spacing: 12) {
                // Provider header
                HStack {
                    Text(name.capitalized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(colorScheme == .dark ? .white : .primary)

                    Spacer()

                    // Edit icon
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.blue)

                    // API Key status
                    if let apiKey = provider.apiKey {
                        let hasConfiguredKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        HStack(spacing: 4) {
                            Image(systemName: hasConfiguredKey ? "key.fill" : "key.slash.fill")
                                .font(.system(size: 12))
                                .foregroundColor(hasConfiguredKey ? .green : .orange)
                            Text(hasConfiguredKey ? "已配置" : "未配置")
                                .font(.caption)
                                .foregroundColor(hasConfiguredKey ? .green : .orange)
                        }
                    }
                }

                // Base URL
                if let baseUrl = provider.baseUrl {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text(baseUrl)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                // Models count
                if let models = provider.models {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                            .font(.system(size: 12))
                            .foregroundColor(.blue)
                        Text("\(models.count) 个模型")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }

                    // Models list (collapsed by default, can expand later)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(models.prefix(3), id: \.id) { model in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.blue.opacity(0.6))
                                    .frame(width: 4, height: 4)
                                Text(model.name ?? model.id)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if models.count > 3 {
                            Text("还有 \(models.count - 3) 个模型...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }
                    .padding(.leading, 8)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(colorScheme == .dark ? Color(.systemGray6).opacity(0.3) : Color(.systemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Error View

    @ViewBuilder
    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("加载失败")
                .font(.headline)

            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(action: {
                Task {
                    await viewModel.loadConfig()
                }
            }) {
                Label("重试", systemImage: "arrow.clockwise")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(10)
            }
        }
    }

    // MARK: - Helpers

    private var cardBackground: some View {
        colorScheme == .dark
            ? Color(.systemGray6).opacity(0.5)
            : Color(.systemBackground)
    }
}

// MARK: - ViewModel

@MainActor
class ModelConfigViewModel: ObservableObject {
    @Published var modelConfig: ModelConfigData?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let client: OpenClawClient
    private var configHash: String? // 用于乐观锁

    init(client: OpenClawClient) {
        self.client = client
    }

    func loadConfig() async {
        isLoading = true
        errorMessage = nil

        do {
            // Call config.get RPC
            let payload: ConfigGetPayload = try await client.sendRPC(method: "config.get", params: nil)

            // Store baseHash for optimistic locking
            configHash = payload.baseHash

            // Convert to ModelConfigData
            let providers = payload.providers.mapValues { providerConfig in
                let models = providerConfig.models?.map { modelId in
                    ModelInfo(
                        id: modelId,
                        name: modelId,
                        reasoning: nil,
                        contextWindow: nil,
                        maxTokens: nil
                    )
                }
                return ProviderConfig(
                    apiKey: providerConfig.apiKey,
                    baseUrl: providerConfig.baseUrl,
                    models: models
                )
            }

            modelConfig = ModelConfigData(
                path: nil,
                exists: true,
                valid: true,
                mode: payload.mode ?? "merge",
                providers: providers
            )

            print("[ModelConfig] ✅ Loaded config - mode: \(payload.mode ?? "merge"), providers: \(payload.providers.keys.joined(separator: ", "))")

        } catch {
            errorMessage = error.localizedDescription
            print("[ModelConfig] Error: \(error)")
        }

        isLoading = false
    }

    // 更新提供商配置（API Key 和 Base URL）
    func updateProvider(name: String, apiKey: String?, baseUrl: String?) async {
        guard let baseHash = configHash else {
            errorMessage = "缺少配置 hash，请重新加载"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            // Build patch object
            var providerPatch: [String: Any] = [:]
            if let apiKey = apiKey, !apiKey.isEmpty {
                providerPatch["apiKey"] = apiKey
            }
            if let baseUrl = baseUrl, !baseUrl.isEmpty {
                providerPatch["baseUrl"] = baseUrl
            }

            guard !providerPatch.isEmpty else {
                errorMessage = "没有可更新的字段"
                isLoading = false
                return
            }

            let rawPatchObject: [String: Any] = [
                "models": [
                    "providers": [
                        name: providerPatch
                    ]
                ]
            ]
            let rawData = try JSONSerialization.data(withJSONObject: rawPatchObject, options: [.prettyPrinted])
            let rawPatch = String(data: rawData, encoding: .utf8) ?? "{}"

            let params: [String: Any] = [
                "baseHash": baseHash,
                "raw": rawPatch
            ]

            // Call config.patch RPC
            let payload: ConfigPatchPayload = try await client.sendRPC(method: "config.patch", params: params)

            if payload.updated {
                // Update local hash
                if let newHash = payload.newHash {
                    configHash = newHash
                }
                // Reload config to show updates
                await loadConfig()
            } else {
                errorMessage = "配置更新失败，可能因为并发冲突"
            }

            print("[ModelConfig] ✅ Updated provider \(name)")

        } catch {
            errorMessage = error.localizedDescription
            print("[ModelConfig] Update error: \(error)")
        }

        isLoading = false
    }

    // 更新配置模式
    func updateMode(_ mode: String) async {
        guard let baseHash = configHash else {
            errorMessage = "缺少配置 hash，请重新加载"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let rawPatchObject: [String: Any] = [
                "models": [
                    "mode": mode
                ]
            ]
            let rawData = try JSONSerialization.data(withJSONObject: rawPatchObject, options: [.prettyPrinted])
            let rawPatch = String(data: rawData, encoding: .utf8) ?? "{}"

            let params: [String: Any] = [
                "baseHash": baseHash,
                "raw": rawPatch
            ]

            // Call config.patch RPC
            let payload: ConfigPatchPayload = try await client.sendRPC(method: "config.patch", params: params)

            if payload.updated {
                // Update local hash
                if let newHash = payload.newHash {
                    configHash = newHash
                }
                // Reload config to show updates
                await loadConfig()
            } else {
                errorMessage = "配置更新失败，可能因为并发冲突"
            }

            print("[ModelConfig] ✅ Updated mode to \(mode)")

        } catch {
            errorMessage = error.localizedDescription
            print("[ModelConfig] Mode update error: \(error)")
        }

        isLoading = false
    }
}

// MARK: - Data Models

struct ModelConfigData {
    let path: String?
    let exists: Bool
    let valid: Bool?
    let mode: String?
    let providers: [String: ProviderConfig]?
}

struct ProviderConfig {
    let apiKey: String?
    let baseUrl: String?
    let models: [ModelInfo]?
}

struct ModelInfo: Identifiable {
    let id: String
    let name: String?
    let reasoning: Bool?
    let contextWindow: Int?
    let maxTokens: Int?
}

// MARK: - Edit Provider Sheet

struct EditProviderSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let providerName: String
    let provider: ProviderConfig
    let onSave: (String?, String?) -> Void

    @State private var apiKey: String = ""
    @State private var baseUrl: String = ""
    @State private var showApiKey: Bool = false

    init(providerName: String, provider: ProviderConfig, onSave: @escaping (String?, String?) -> Void) {
        self.providerName = providerName
        self.provider = provider
        self.onSave = onSave
        _baseUrl = State(initialValue: provider.baseUrl ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text("编辑 \(providerName.capitalized) 配置")
                        .font(.headline)
                } header: {
                    Text("提供商信息")
                }

                Section {
                    HStack {
                        if showApiKey {
                            TextField("输入 API Key", text: $apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("输入 API Key", text: $apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        Button(action: { showApiKey.toggle() }) {
                            Image(systemName: showApiKey ? "eye.slash.fill" : "eye.fill")
                                .foregroundColor(.secondary)
                        }
                    }

                    if let existingKey = provider.apiKey,
                       !existingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("当前已配置 API Key")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                } header: {
                    Text("API Key")
                } footer: {
                    Text("留空则不修改现有配置")
                }

                Section {
                    TextField("Base URL", text: $baseUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Base URL")
                } footer: {
                    Text("API 端点地址，留空则使用默认值")
                }

                if let models = provider.models {
                    Section {
                        ForEach(models.prefix(5), id: \.id) { model in
                            HStack {
                                Text(model.name ?? model.id)
                                    .font(.subheadline)
                                Spacer()
                                if let contextWindow = model.contextWindow {
                                    Text("\(contextWindow / 1000)K")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        if models.count > 5 {
                            Text("还有 \(models.count - 5) 个模型...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } header: {
                        Text("可用模型 (\(models.count))")
                    }
                }
            }
            .navigationTitle("编辑提供商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        let newApiKey = apiKey.isEmpty ? nil : apiKey
                        let newBaseUrl = baseUrl.isEmpty ? nil : baseUrl
                        onSave(newApiKey, newBaseUrl)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// Make String identifiable for sheet binding
extension String: Identifiable {
    public var id: String { self }
}
