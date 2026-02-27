//
//  ConfigModels.swift
//  contextgo
//
//  OpenClaw config.get / config.patch RPC models
//

import Foundation

// MARK: - Generic RPC Response

struct GenericRPCResponse<T: Decodable>: Decodable {
    let type: String
    let ok: Bool
    let id: String
    let payload: T?
    let error: ErrorPayload?

    struct ErrorPayload: Decodable {
        let message: String
        let code: String?
    }
}

// MARK: - Config.get Response

struct ConfigGetPayload: Decodable {
    let mode: String?
    let baseHash: String?
    let providers: [String: ProviderConfig]

    enum CodingKeys: String, CodingKey {
        case mode
        case baseHash
        case providers
        case models
        case hash
        case config
    }

    struct ModelsContainer: Decodable {
        let mode: String?
        let providers: [String: ProviderConfig]?
    }

    struct ConfigContainer: Decodable {
        let mode: String?
        let baseHash: String?
        let hash: String?
        let providers: [String: ProviderConfig]?
        let models: ModelsContainer?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let nestedModels = try container.decodeIfPresent(ModelsContainer.self, forKey: .models)
        let nestedConfig = try container.decodeIfPresent(ConfigContainer.self, forKey: .config)

        let rootMode = try container.decodeIfPresent(String.self, forKey: .mode)
        let rootBaseHash = try container.decodeIfPresent(String.self, forKey: .baseHash)
        let fallbackHash = try container.decodeIfPresent(String.self, forKey: .hash)
        let rootProviders = try container.decodeIfPresent([String: ProviderConfig].self, forKey: .providers)

        mode = rootMode ?? nestedModels?.mode ?? nestedConfig?.mode ?? nestedConfig?.models?.mode
        baseHash = rootBaseHash ?? fallbackHash ?? nestedConfig?.baseHash ?? nestedConfig?.hash
        providers = rootProviders
            ?? nestedModels?.providers
            ?? nestedConfig?.providers
            ?? nestedConfig?.models?.providers
            ?? [:]
    }

    struct ProviderConfig: Codable {
        let apiKey: String?
        let baseUrl: String?
        let models: [String]?

        enum CodingKeys: String, CodingKey {
            case apiKey
            case baseUrl
            case models
        }

        struct ModelObject: Decodable {
            let id: String?
            let name: String?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            self.apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)

            self.baseUrl = try container.decodeIfPresent(String.self, forKey: .baseUrl)

            if let modelIds = try? container.decodeIfPresent([String].self, forKey: .models) {
                self.models = modelIds
            } else if let modelObjects = try? container.decodeIfPresent([ModelObject].self, forKey: .models) {
                self.models = modelObjects.compactMap { $0.id ?? $0.name }
            } else {
                self.models = nil
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(apiKey, forKey: .apiKey)
            try container.encodeIfPresent(baseUrl, forKey: .baseUrl)
            try container.encodeIfPresent(models, forKey: .models)
        }
    }
}

// MARK: - Config.patch Response

struct ConfigPatchPayload: Codable {
    let updated: Bool
    let newHash: String?
}
