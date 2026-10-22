import SwiftUI

/// One saved Ask AI conversation. Kept on this device only.
struct SavedChat: Codable, Identifiable {
    let id: UUID
    var title: String
    var updated: Date
    var turns: [StoredTurn]
}

struct StoredTurn: Codable {
    let fromUser: Bool
    let text: String
}

/// Recent chats per file. Hidden-vault files are never saved (the sheet checks that).
enum ChatHistoryStore {
    private static func key(_ itemID: UUID) -> String { "ai_chats_\(itemID.uuidString)" }

    static func all(for itemID: UUID) -> [SavedChat] {
        guard let data = UserDefaults.standard.data(forKey: key(itemID)),
              let chats = try? JSONDecoder().decode([SavedChat].self, from: data) else { return [] }
        return chats.sorted { $0.updated > $1.updated }
    }

    static func save(_ chat: SavedChat, for itemID: UUID) {
        var chats = all(for: itemID).filter { $0.id != chat.id }
        chats.insert(chat, at: 0)
        write(Array(chats.prefix(20)), for: itemID)
    }

    static func delete(_ id: UUID, for itemID: UUID) {
        write(all(for: itemID).filter { $0.id != id }, for: itemID)
    }

    private static func write(_ chats: [SavedChat], for itemID: UUID) {
        if let data = try? JSONEncoder().encode(chats) {
            UserDefaults.standard.set(data, forKey: key(itemID))
        }
    }
}

/// The Recent chats list: tap to reopen, swipe to delete.
struct ChatHistoryList: View {
    let itemID: UUID
    let onOpen: (SavedChat) -> Void

    @State private var chats: [SavedChat] = []

    var body: some View {
        NavigationView {
            List {
                ForEach(chats) { chat in
                    Button { onOpen(chat) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chat.title).lineLimit(2)
                            Text(chat.updated, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { ChatHistoryStore.delete(chats[index].id, for: itemID) }
                    chats = ChatHistoryStore.all(for: itemID)
                }
            }
            .overlay {
                if chats.isEmpty { Text("No chats yet.").foregroundStyle(.secondary) }
            }
            .navigationTitle("Recent chats")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { chats = ChatHistoryStore.all(for: itemID) }
        }
    }
}
