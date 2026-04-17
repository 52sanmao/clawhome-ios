import Foundation

@MainActor
final class LocalOpenClawGatewayStore: ObservableObject {
    static let shared = LocalOpenClawGatewayStore()

    @Published private(set) var gateways: [LocalOpenClawGateway] = []

    private let storageKey = "clawhome.openclaw.gateways.v1"
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func load() {
        guard let data = defaults.data(forKey: storageKey) else {
            gateways = []
            return
        }

        do {
            gateways = try decoder.decode([LocalOpenClawGateway].self, from: data)
                .sorted(by: { $0.updatedAt > $1.updatedAt })
        } catch {
            print("[ClawHomeStore] Failed to decode gateways: \(error)")
            gateways = []
        }
    }

    func add(name: String, wsURL: String, token: String) {
        let gateway = LocalOpenClawGateway(name: name, wsURL: wsURL, token: token)
        gateways.insert(gateway, at: 0)
        persist()
    }

    func update(id: String, name: String, wsURL: String, token: String) {
        guard let index = gateways.firstIndex(where: { $0.id == id }) else { return }
        gateways[index].name = name
        gateways[index].wsURL = wsURL
        gateways[index].token = token
        gateways[index].updatedAt = Date()
        gateways.sort(by: { $0.updatedAt > $1.updatedAt })
        persist()
    }

    func delete(id: String) {
        gateways.removeAll(where: { $0.id == id })
        persist()
    }

    func cloudAgent(for id: String) -> CloudAgent? {
        gateways.first(where: { $0.id == id })?.cloudAgent
    }

    private func persist() {
        do {
            let data = try encoder.encode(gateways)
            defaults.set(data, forKey: storageKey)
        } catch {
            print("[ClawHomeStore] Failed to persist gateways: \(error)")
        }
    }
}
