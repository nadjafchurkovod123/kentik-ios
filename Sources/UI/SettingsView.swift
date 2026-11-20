import SwiftUI
import WebKit

/// Модель экрана настроек: читает и пишет AppSettings и щит (ShieldControlling).
@MainActor
final class SettingsModel: ObservableObject {

    private let settings = AppSettings.shared
    private let shield: ShieldControlling

    @Published var searchEngine: SearchEngine {
        didSet { if settings.searchEngine != searchEngine { settings.searchEngine = searchEngine } }
    }
    @Published var addressBarPosition: AddressBarPosition {
        didSet { if settings.addressBarPosition != addressBarPosition { settings.addressBarPosition = addressBarPosition } }
    }
    @Published var shieldEnabled: Bool {
        didSet { if shield.isEnabledGlobally != shieldEnabled { shield.isEnabledGlobally = shieldEnabled } }
    }
    @Published private(set) var faceID: Bool
    @Published private(set) var disabledHosts: [String] = []
    @Published private(set) var updatingLists = false
    @Published var message: String?
    @Published private(set) var incognitoTabCount = 0

    /// Действия, которые выполняет браузер.
    var closeAllIncognito: () -> Void = {}
    var dismiss: () -> Void = {}
    var openHistory: () -> Void = {}
    var openDownloads: () -> Void = {}
    var incognitoCount: () -> Int = { 0 }

    init(shield: ShieldControlling) {
        self.shield = shield
        searchEngine = settings.searchEngine
        addressBarPosition = settings.addressBarPosition
        shieldEnabled = shield.isEnabledGlobally
        faceID = settings.incognitoFaceID
        refresh()
    }

    func refresh() {
        shieldEnabled = shield.isEnabledGlobally
        disabledHosts = BlockingSettings.shared.disabledHosts.sorted()
        incognitoTabCount = incognitoCount()
    }

    func enableShield(on host: String) {
        shield.setEnabled(true, forHost: host)
        refresh()
    }

    func reloadLists() {
        updatingLists = true
        let before = ContentBlocker.shared.activeVersion
        shield.reloadRules { [weak self] error in
            guard let self else { return }
            self.updatingLists = false
            if let error {
                self.message = "Не удалось обновить списки: \(error.localizedDescription)"
            } else if ContentBlocker.shared.activeVersion != before {
                self.message = "Списки фильтров обновлены. Новые правила действуют со следующей загрузки страницы"
            } else {
                self.message = "Списки фильтров уже свежие"
            }
            self.objectWillChange.send()
        }
    }

    /// Дата списков и последняя проверка обновлений (с предупреждением, если устарели).
    var listsFreshness: FilterLists.Freshness {
        FilterLists.freshness(version: listsVersion, lastCheck: FilterListUpdater.shared.lastCheck)
    }

    /// Предупреждение о неполной блокировке (часть списков не скомпилировалась).
    var incompleteWarning: String? { ShieldSheetViewController.incompleteText() }

    func setFaceID(_ on: Bool) {
        guard on else {
            settings.incognitoFaceID = false
            faceID = false
            return
        }
        // Включаем только после успешной проверки — чтобы не запереться.
        IncognitoLock.authenticate(reason: "Включить Face ID для инкогнито") { [weak self] ok in
            guard let self else { return }
            self.settings.incognitoFaceID = ok
            self.faceID = ok
        }
    }

    func closeIncognito() {
        closeAllIncognito()
        refresh()
        message = "Вкладки инкогнито закрыты, сессия стёрта"
    }

    func clearHistory() {
        HistoryStore.shared.removeAll()
        TileStore.shared.resetHidden()
        message = "История очищена"
    }

    func clearWebsiteData() {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            Task { @MainActor in self?.message = "Куки, кэш и данные сайтов удалены" }
        }
    }

    func resetZoom() {
        SiteZoom.shared.resetAll()
        message = "Масштаб сайтов сброшен"
    }

    /// Версия активных списков (скачанные новее встроенных — показываем их).
    var listsVersion: String { ContentBlocker.shared.activeVersion ?? FilterLists.version }
}

/// Экран настроек.
struct SettingsView: View {

    @ObservedObject var model: SettingsModel
    @State private var confirmClearHistory = false
    @State private var confirmClearData = false

    private let rowBackground = Color(Theme.bar)

    var body: some View {
        NavigationStack {
            Form {
                Section("Поиск") {
                    Picker("Поисковая система", selection: $model.searchEngine) {
                        ForEach(SearchEngine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .accessibilityIdentifier("searchEnginePicker")
                }
                .listRowBackground(rowBackground)

                Section {
                    Picker("Адресная строка", selection: $model.addressBarPosition) {
                        ForEach(AddressBarPosition.allCases) { position in
                            Text(position.title).tag(position)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("addressBarPositionPicker")
                } header: {
                    Text("Адресная строка")
                } footer: {
                    Text("Снизу удобнее одной рукой. Смахните по адресной строке влево или вправо, чтобы переключить вкладку.")
                }
                .listRowBackground(rowBackground)

                Section {
                    Toggle(isOn: $model.shieldEnabled) {
                        Label("Блокировка рекламы", systemImage: "shield.lefthalf.filled")
                    }
                    .accessibilityIdentifier("settingsShieldToggle")
                    Button {
                        model.reloadLists()
                    } label: {
                        HStack {
                            Label("Обновить списки фильтров", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if model.updatingLists { ProgressView() }
                        }
                    }
                    .disabled(model.updatingLists)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.listsFreshness.text)
                            .font(.footnote)
                            .foregroundStyle(model.listsFreshness.isStale ? Color(Theme.warn) : Color(Theme.dim))
                        if let warning = model.incompleteWarning {
                            Text(warning)
                                .font(.footnote)
                                .foregroundStyle(Color(Theme.warn))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settingsListsFreshness")
                    if !model.disabledHosts.isEmpty {
                        DisclosureGroup("Выключена на сайтах (\(model.disabledHosts.count))") {
                            ForEach(model.disabledHosts, id: \.self) { host in
                                HStack {
                                    Text(host)
                                    Spacer()
                                    Button("Включить") { model.enableShield(on: host) }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Блокировка рекламы")
                } footer: {
                    Text("Блокирует рекламу, всплывающие окна и рекламные переходы. На отдельном сайте её можно выключить кнопкой щита в адресной строке.")
                }
                .listRowBackground(rowBackground)

                Section {
                    Toggle(isOn: Binding(get: { model.faceID }, set: { model.setFaceID($0) })) {
                        Label("Face ID для инкогнито", systemImage: "faceid")
                    }
                    .accessibilityIdentifier("faceIDToggle")
                    Button(role: .destructive) {
                        model.closeIncognito()
                    } label: {
                        Label("Закрыть все вкладки инкогнито", systemImage: "eye.slash")
                    }
                    .disabled(model.incognitoTabCount == 0)
                } header: {
                    Text("Инкогнито")
                } footer: {
                    Text("Вкладки инкогнито не пишут историю. Куки и кэш живут только в памяти и стираются, когда закрыта последняя вкладка инкогнито.")
                }
                .listRowBackground(rowBackground)

                Section("Данные") {
                    Button { model.openHistory() } label: {
                        Label("История", systemImage: "clock")
                    }
                    Button { model.openDownloads() } label: {
                        Label("Загрузки", systemImage: "arrow.down.circle")
                    }
                    Button(role: .destructive) { confirmClearHistory = true } label: {
                        Label("Очистить историю", systemImage: "clock.badge.xmark")
                    }
                    .confirmationDialog("Очистить всю историю?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
                        Button("Очистить историю", role: .destructive) { model.clearHistory() }
                    }
                    Button(role: .destructive) { confirmClearData = true } label: {
                        Label("Удалить куки и кэш", systemImage: "trash")
                    }
                    .confirmationDialog("Удалить куки, кэш и данные сайтов? Придётся заново входить на сайты.",
                                        isPresented: $confirmClearData, titleVisibility: .visible) {
                        Button("Удалить", role: .destructive) { model.clearWebsiteData() }
                    }
                    Button { model.resetZoom() } label: {
                        Label("Сбросить масштаб сайтов", systemImage: "textformat.size")
                    }
                }
                .listRowBackground(rowBackground)

                Section {
                    LabeledContent("Версия", value: AppSettings.versionString)
                    LabeledContent("Ссылки", value: "kentik://open?url=…")
                } header: {
                    Text("О приложении")
                } footer: {
                    Text("Kentik для iPhone — простой браузер с блокировкой рекламы. Ссылки kentik:// открываются в Kentik (например, из «Быстрых команд»).")
                }
                .listRowBackground(rowBackground)
            }
            .scrollContentBackground(.hidden)
            .background(Color(Theme.background))
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { model.dismiss() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("settingsDone")
                }
            }
            .alert(model.message ?? "", isPresented: Binding(
                get: { model.message != nil },
                set: { if !$0 { model.message = nil } }
            )) {
                Button("OK", role: .cancel) {}
            }
        }
        .tint(Color(Theme.violet))
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("settingsView")
    }
}
