import SwiftUI

/// История обычных вкладок: по дням, с поиском, удалением смахиванием и очисткой.
struct HistoryView: View {

    @ObservedObject var store: HistoryStore
    var onOpen: (URL) -> Void
    var onDone: () -> Void

    @State private var query = ""
    @State private var confirmClear = false

    private struct DaySection: Identifiable {
        let id: Date
        let title: String
        let items: [HistoryEntry]
    }

    private var sections: [DaySection] {
        let calendar = Calendar.current
        let items = store.search(query)
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.lastVisit) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return grouped.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) {
                title = "Сегодня"
            } else if calendar.isDateInYesterday(day) {
                title = "Вчера"
            } else {
                title = formatter.string(from: day)
            }
            return DaySection(id: day, title: title, items: grouped[day] ?? [])
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { entry in
                            Button {
                                onOpen(entry.url)
                            } label: {
                                HistoryRow(entry: entry)
                            }
                            .listRowBackground(Color(Theme.bar))
                            .swipeActions {
                                Button(role: .destructive) {
                                    store.remove(entry)
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(Theme.background))
            .overlay {
                if store.entries.isEmpty {
                    ContentUnavailableView("История пуста", systemImage: "clock",
                                           description: Text("Здесь появятся сайты из обычных вкладок. Инкогнито историю не пишет."))
                } else if sections.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск в истории")
            .navigationTitle("История")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Очистить", role: .destructive) { confirmClear = true }
                        .disabled(store.entries.isEmpty)
                        .accessibilityIdentifier("clearHistory")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { onDone() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("historyDone")
                }
            }
            .confirmationDialog("Очистить всю историю?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Очистить историю", role: .destructive) { store.removeAll() }
            }
        }
        .tint(Color(Theme.violet))
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("historyView")
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.host.first.map { String($0).uppercased() } ?? "•")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color(Theme.violet).opacity(0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? entry.host : entry.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(Theme.text))
                    .lineLimit(1)
                Text(entry.url.absoluteString)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(Theme.faint))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(Self.timeFormatter.string(from: entry.lastVisit))
                .font(.system(size: 12))
                .foregroundStyle(Color(Theme.faint))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("historyRow")
    }
}
