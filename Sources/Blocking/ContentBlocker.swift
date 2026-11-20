import WebKit

/// Блокировщик рекламы на WKContentRuleList.
///
/// Каркас: умеет только тестовый список (-KentikTestRules). Настоящие списки, обновление
/// и выключение по сайтам добавит агент блокировщика.
@MainActor
final class ContentBlocker {

    static let shared = ContentBlocker()

    /// Скомпилированные списки, которые ставятся в каждую новую веб-вью.
    private(set) var ruleLists: [WKContentRuleList] = []
    private(set) var isReady = false
    private var pending: [@MainActor () -> Void] = []
    private var isCompiling = false

    /// Готовит (компилирует) правила. completion вызывается на главном потоке, когда
    /// правила готовы; до этого первую вкладку открывать не стоит.
    func prepare(completion: @escaping @MainActor () -> Void) {
        if isReady {
            completion()
            return
        }
        pending.append(completion)
        guard !isCompiling else { return }
        isCompiling = true
        compileLists { [weak self] lists in
            guard let self else { return }
            self.ruleLists = lists
            self.isReady = true
            self.isCompiling = false
            let callbacks = self.pending
            self.pending.removeAll()
            callbacks.forEach { $0() }
        }
    }

    /// Хук фабрики: ставит правила в контроллер новой веб-вью.
    /// - Parameters:
    ///   - host: хост, если известен заранее (для выключения щита на сайте).
    ///   - incognito: вкладка инкогнито.
    func install(on controller: WKUserContentController, host: String?, incognito: Bool) {
        guard BlockingSettings.shared.isEnabled(forHost: host) else { return }
        for list in ruleLists {
            controller.add(list)
        }
    }

    /// Перекомпилировать все списки.
    func reloadRules(completion: @escaping @MainActor (Error?) -> Void) {
        isReady = false
        prepare { completion(nil) }
    }

    // MARK: - Компиляция

    private func compileLists(completion: @escaping @MainActor ([WKContentRuleList]) -> Void) {
        guard TestHooks.useTestRules else {
            completion([])
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: FilterLists.testRulesIdentifier,
            encodedContentRuleList: FilterLists.testRulesJSON
        ) { list, error in
            if let error {
                NSLog("[Kentik] тестовые правила не скомпилировались: %@", error.localizedDescription)
            }
            let lists = list.map { [$0] } ?? []
            Task { @MainActor in
                completion(lists)
            }
        }
    }
}
