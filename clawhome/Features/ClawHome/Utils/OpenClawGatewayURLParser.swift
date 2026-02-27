import Foundation

enum OpenClawGatewayURLParser {
    private static let queryKeys = ["ws", "wsURL", "gateway", "gatewayURL", "url"]

    static func parse(raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isValidWebSocketURL(trimmed) {
            return trimmed
        }

        if let decoded = trimmed.removingPercentEncoding, isValidWebSocketURL(decoded) {
            return decoded
        }

        if let fromURL = parseFromURLComponents(trimmed) {
            return fromURL
        }

        if let fromJSON = parseFromJSON(trimmed) {
            return fromJSON
        }

        if let data = Data(base64URLEncoded: trimmed),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let parsed = parseFromJSONDictionary(json) {
            return parsed
        }

        return nil
    }

    static func isValidWebSocketURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased() else {
            return false
        }

        return scheme == "ws" || scheme == "wss"
    }

    private static func parseFromURLComponents(_ value: String) -> String? {
        guard let components = URLComponents(string: value) else { return nil }

        if let directURL = components.url?.absoluteString,
           isValidWebSocketURL(directURL) {
            return directURL
        }

        for key in queryKeys {
            if let queryValue = components.queryItems?.first(where: { $0.name == key })?.value {
                if isValidWebSocketURL(queryValue) {
                    return queryValue
                }

                if let decoded = queryValue.removingPercentEncoding,
                   isValidWebSocketURL(decoded) {
                    return decoded
                }
            }
        }

        return nil
    }

    private static func parseFromJSON(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return parseFromJSONDictionary(json)
    }

    private static func parseFromJSONDictionary(_ json: [String: Any]) -> String? {
        for key in queryKeys {
            if let value = json[key] as? String, isValidWebSocketURL(value) {
                return value
            }
        }
        return nil
    }
}
