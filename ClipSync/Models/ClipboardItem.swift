import Foundation

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let content: String
    let timestamp: Date
    let source: String
    
    init(id: UUID = UUID(), content: String, timestamp: Date = Date(), source: String = "手机") {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.source = source
    }
    
    var displayContent: String {
        if content.count > 50 {
            return String(content.prefix(50)) + "..."
        }
        return content
    }
    
    var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }
}

class ClipboardStore: ObservableObject {
    @Published var items: [ClipboardItem] = []
    private let maxItems = 20
    private let userDefaultsKey = "clipboardItems"
    
    init() {
        loadItems()
    }
    
    func addItem(_ content: String, source: String = "手机") {
        let item = ClipboardItem(content: content, source: source)
        DispatchQueue.main.async {
            // 避免重复
            if let lastItem = self.items.first, lastItem.content == content {
                return
            }
            self.items.insert(item, at: 0)
            if self.items.count > self.maxItems {
                self.items = Array(self.items.prefix(self.maxItems))
            }
            self.saveItems()
        }
    }
    
    func removeItem(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        saveItems()
    }
    
    func clearAll() {
        items.removeAll()
        saveItems()
    }
    
    private func loadItems() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else {
            return
        }
        items = decoded
    }
    
    private func saveItems() {
        guard let encoded = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
    }
}
