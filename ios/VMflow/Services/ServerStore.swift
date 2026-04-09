import Foundation

@MainActor
final class ServerStore: ObservableObject {
    static let shared = ServerStore()

    private let serversKey = "savedServers"
    private let selectedKey = "selectedServerId"

    let defaultServer: ServerEntry

    @Published private(set) var customServers: [ServerEntry] = []

    var allServers: [ServerEntry] {
        [defaultServer] + customServers
    }

    var selectedServer: ServerEntry {
        if let idString = UserDefaults.standard.string(forKey: selectedKey),
           let id = UUID(uuidString: idString),
           let match = allServers.first(where: { $0.id == id }) {
            return match
        }
        return defaultServer
    }

    private init() {
        defaultServer = ServerEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "VMflow Cloud",
            url: AppConfig.supabaseURL.absoluteString,
            anonKey: AppConfig.supabaseAnonKey,
            isDefault: true
        )
        loadCustomServers()
    }

    func selectServer(_ server: ServerEntry) {
        UserDefaults.standard.set(server.id.uuidString, forKey: selectedKey)
        objectWillChange.send()
    }

    func addServer(_ server: ServerEntry) {
        var entry = server
        entry.url = entry.sanitizedURL
        customServers.append(entry)
        saveCustomServers()
    }

    func updateServer(_ server: ServerEntry) {
        guard let idx = customServers.firstIndex(where: { $0.id == server.id }) else { return }
        var entry = server
        entry.url = entry.sanitizedURL
        customServers[idx] = entry
        saveCustomServers()
    }

    func deleteServer(_ server: ServerEntry) {
        guard !server.isDefault else { return }
        let wasSelected = selectedServer.id == server.id
        customServers.removeAll { $0.id == server.id }
        if wasSelected {
            selectServer(defaultServer)
        }
        saveCustomServers()
    }

    private func loadCustomServers() {
        guard let data = UserDefaults.standard.data(forKey: serversKey) else { return }
        customServers = (try? JSONDecoder().decode([ServerEntry].self, from: data)) ?? []
    }

    private func saveCustomServers() {
        let data = try? JSONEncoder().encode(customServers)
        UserDefaults.standard.set(data, forKey: serversKey)
    }
}
