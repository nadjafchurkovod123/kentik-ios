import WebKit

extension Notification.Name {
    /// Изменился текст состояния блокировщика (подготовка списков). Читать ContentBlocker.shared.statusText.
    static let contentBlockerStatusChanged = Notification.Name("KentikContentBlockerStatusChanged")
    /// Активные списки заменены (обновление). Новые правила применяются со следующей загрузки страницы.
    static let contentBlockerListsChanged = Notification.Name("KentikContentBlockerListsChanged")
}

/// Блокировщик рекламы на WKContentRuleList.
///
/// Списки (сеть + косметика) компилируются один раз и кэшируются в WKContentRuleListStore по
/// sha256. Правила ставятся в WKUserContentController каждой веб-вью и действуют на все фреймы,
/// включая iframe плееров.
///
/// Выключение «на сайте» и общий выключатель: списки WebKit независимы друг от друга
/// (ignore-previous-rules не отменяет правила из другого списка), поэтому вместо
/// списка-исключения мы снимаем наши списки с контроллера веб-вью перед навигацией главного
/// фрейма на выключенный сайт и возвращаем их на остальных — так щит выключается и для
/// страницы, и для всех её iframe. Это делает `prepareNavigation(of:to:)`, его вызывает
/// TabWebDelegate до `decisionHandler(.allow)`.
@MainActor
final class ContentBlocker {

    static let shared = ContentBlocker()

    /// Активные скомпилированные списки (тестовый, если включён, — первым).
    private(set) var ruleLists: [WKContentRuleList] = []
    private(set) var isReady = false
    /// Версия активного набора списков (nil — списков нет, например локальная сборка без CI).
    private(set) var activeVersion: String?
    private(set) var activeOrigin: FilterLists.Package.Origin?
    /// Названия списков, которые не скомпилировались при последней загрузке.
    private(set) var failedLists: [String] = []
    /// Короткий статус для пользователя («Готовлю блокировщик рекламы…»), nil — всё готово.
    private(set) var statusText: String? {
        didSet {
            guard statusText != oldValue else { return }
            NotificationCenter.default.post(name: .contentBlockerStatusChanged, object: self)
        }
    }

    private let settings: BlockingSettings
    private let compiler: RuleListCompiler
    private var testList: WKContentRuleList?
    private var pending: [@MainActor () -> Void] = []
    private var isCompiling = false
    /// Что из наших списков сейчас стоит на каждом контроллере (слабые ключи).
    private let installed = NSMapTable<WKUserContentController, InstalledLists>.weakToStrongObjects()

    private final class InstalledLists {
        var lists: [WKContentRuleList] = []
    }

    /// nil — общие настройки и хранилище по умолчанию (аргументы по умолчанию не могут
    /// обращаться к главному актору, поэтому подставляем их здесь).
    init(settings: BlockingSettings? = nil, compiler: RuleListCompiler? = nil) {
        self.settings = settings ?? .shared
        self.compiler = compiler ?? RuleListCompiler()
    }

    // MARK: - Подготовка

    /// Готовит (компилирует) правила. completion вызывается на главном потоке, когда правила
    /// готовы — или по тайм-ауту, чтобы первая страница не ждала вечно (тогда правила встанут
    /// со следующей навигации).
    func prepare(completion: @escaping @MainActor () -> Void) {
        if isReady {
            completion()
            return
        }
        pending.append(completion)
        guard !isCompiling else { return }
        isCompiling = true
        BlockerStatusBanner.start()

        let timeout: TimeInterval = TestHooks.isUITest ? 300 : 60
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.pending.isEmpty else { return }
            NSLog("[Kentik] списки ещё компилируются — открываю страницу без ожидания")
            self.flushPending()
        }

        Task { @MainActor in
            await self.loadActiveLists()
            self.isReady = true
            self.isCompiling = false
            self.flushPending()
            FilterListUpdater.shared.scheduleDailyCheck()
        }
    }

    private func flushPending() {
        let callbacks = pending
        pending.removeAll()
        callbacks.forEach { $0() }
    }

    /// Загружает лучший доступный набор: самый свежий из встроенного и скачанного; если он не
    /// компилируется — следующий. Частичный успех лучше, чем ничего.
    private func loadActiveLists() async {
        if TestHooks.useTestRules, testList == nil {
            testList = await compileTestRules()
        }

        var packages = [FilterLists.downloadedPackage(), FilterLists.bundledPackage()].compactMap { $0 }
        packages.sort { FilterListManifest.isVersion($0.manifest.version, newerThan: $1.manifest.version) }
        if packages.isEmpty {
            NSLog("[Kentik] встроенных списков нет (сборка без CI) — блокировка только тестовыми правилами")
        }

        var best: (FilterLists.Package, RuleListCompiler.Result)?
        for package in packages {
            let result = await compile(package)
            if result.failures.isEmpty {
                best = (package, result)
                break
            }
            if best == nil || result.lists.count > best!.1.lists.count {
                best = (package, result)
            }
        }
        statusText = nil

        if let best, !best.1.lists.isEmpty {
            activate(best.0, result: best.1)
        } else {
            // Ни один список не скомпилировался (например, мало места): блокировка не работает.
            // Версию не ставим (щит не делает вид, что всё в порядке) и кэш не чистим.
            ruleLists = testList.map { [$0] } ?? []
            activeVersion = nil
            activeOrigin = nil
            failedLists = best?.1.failures.map(\.name) ?? []
            if best != nil {
                NSLog("[Kentik] ни один список не скомпилировался — блокировка рекламы не работает")
            }
        }
    }

    /// Списков ожидалось больше, чем работает (часть или все не скомпилировались).
    var isIncomplete: Bool { !failedLists.isEmpty }

    private func compile(_ package: FilterLists.Package) async -> RuleListCompiler.Result {
        let entries = package.manifest.entries()
        let sources = entries.map { entry in
            RuleListCompiler.Source(
                identifier: entry.storeIdentifier,
                name: "\(entry.id) (\(package.origin.rawValue) \(package.manifest.version))",
                load: { [url = package.fileURL(for: entry)] in try FilterLists.loadJSON(from: url) }
            )
        }
        return await compiler.compile(sources) { [weak self] index, total in
            self?.statusText = "Готовлю блокировщик рекламы… \(index) из \(total)"
        }
    }

    private func activate(_ package: FilterLists.Package, result: RuleListCompiler.Result) {
        ruleLists = (testList.map { [$0] } ?? []) + result.lists
        activeVersion = package.manifest.version
        activeOrigin = package.origin
        failedLists = result.failures.map(\.name)
        compiler.removeStale(keeping: Set(result.compiledIdentifiers))
        let rules = package.manifest.entries().reduce(0) { $0 + ($1.rules ?? 0) }
        NSLog("[Kentik] активны %@ списки %@: %d шт., ~%d правил, не скомпилировались: %d",
              package.origin.rawValue, package.manifest.version, result.lists.count, rules, result.failures.count)
    }

    private func compileTestRules() async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: FilterLists.testRulesIdentifier,
                encodedContentRuleList: FilterLists.testRulesJSON
            ) { list, error in
                if let error {
                    NSLog("[Kentik] тестовые правила не скомпилировались: %@", error.localizedDescription)
                }
                continuation.resume(returning: list)
            }
        }
    }

    // MARK: - Обновление

    /// Компилирует скачанный набор и, если скомпилировалось ВСЁ, атомарно подменяет активные
    /// списки. При любой ошибке текущие списки остаются как были.
    func activateDownloaded(_ package: FilterLists.Package) async throws {
        let result = await compile(package)
        statusText = nil
        guard result.failures.isEmpty, !result.lists.isEmpty else {
            let names = result.failures.map(\.name).joined(separator: ", ")
            throw RuleListCompiler.CompileError(message: "Не скомпилировались списки: \(names)")
        }
        activate(package, result: result)
        NotificationCenter.default.post(name: .contentBlockerListsChanged, object: self)
    }

    /// Пересобрать правила: проверить обновление списков (без ограничения «раз в сутки») и
    /// перекомпилировать. completion(nil) — списки актуальны или обновлены.
    func reloadRules(completion: @escaping @MainActor (Error?) -> Void) {
        prepare {
            FilterListUpdater.shared.checkNow { result in
                switch result {
                case .success: completion(nil)
                case .failure(let error): completion(error)
                }
            }
        }
    }

    // MARK: - Установка в веб-вью

    /// Хук фабрики: ставит правила в контроллер новой веб-вью.
    /// - Parameters:
    ///   - host: хост, если известен заранее (nil — по общему выключателю).
    ///   - incognito: вкладка инкогнито (настройки щита общие, правила те же).
    func install(on controller: WKUserContentController, host: String?, incognito: Bool) {
        sync(controller, host: host, incognito: incognito)
    }

    /// Вызывать перед навигацией главного фрейма (до decisionHandler(.allow)): ставит или
    /// снимает наши списки по настройкам сайта, куда идём. Сообщения WebKit в процесс страницы
    /// упорядочены, поэтому правила успевают примениться к этой загрузке и её iframe.
    func prepareNavigation(of webView: WKWebView, to url: URL?) {
        let incognito = !webView.configuration.websiteDataStore.isPersistent
        sync(webView.configuration.userContentController, host: url?.host, incognito: incognito)
    }

    /// Какие списки должны стоять для хоста.
    func desiredLists(forHost host: String?, incognito: Bool = false) -> [WKContentRuleList] {
        settings.isEnabled(forHost: host, incognito: incognito) ? ruleLists : []
    }

    /// Наши списки, которые сейчас стоят на контроллере (для тестов и статистики).
    func installedLists(on controller: WKUserContentController) -> [WKContentRuleList] {
        installed.object(forKey: controller)?.lists ?? []
    }

    func sync(_ controller: WKUserContentController, host: String?, incognito: Bool = false) {
        let desired = desiredLists(forHost: host, incognito: incognito)
        let state = installed.object(forKey: controller) ?? InstalledLists()
        let current = state.lists
        if current.count == desired.count && zip(current, desired).allSatisfy({ $0 === $1 }) {
            installed.setObject(state, forKey: controller)
            return
        }
        let desiredSet = Set(desired.map(ObjectIdentifier.init))
        let currentSet = Set(current.map(ObjectIdentifier.init))
        for list in current where !desiredSet.contains(ObjectIdentifier(list)) {
            controller.remove(list)
        }
        for list in desired where !currentSet.contains(ObjectIdentifier(list)) {
            controller.add(list)
        }
        state.lists = desired
        installed.setObject(state, forKey: controller)
    }

    /// Для модульных тестов: подставить готовые списки.
    func setRuleListsForTesting(_ lists: [WKContentRuleList]) {
        ruleLists = lists
        isReady = true
    }

    // MARK: - Статистика

    /// После загрузки страницы оценивает, сколько рекламных элементов спрятано косметикой.
    /// WebKit не сообщает о срабатываниях правил, поэтому считаем скрытые (display: none)
    /// элементы с «рекламными» классами и id — это приближение.
    func pageDidFinishLoading(tab: Tab) {
        guard settings.isEnabled(forHost: tab.host, incognito: tab.isIncognito), !ruleLists.isEmpty else {
            if tab.hiddenByRules != 0 {
                tab.hiddenByRules = 0
                tab.notifyChanged()
            }
            return
        }
        tab.webView.evaluateJavaScript(Self.hiddenEstimateScript) { [weak tab] value, _ in
            MainActor.assumeIsolated {
                guard let tab, let count = value as? Int else { return }
                if tab.hiddenByRules != count {
                    tab.hiddenByRules = count
                    tab.notifyChanged()
                }
            }
        }
    }

    private static let hiddenEstimateScript = """
    (() => {
      const re = /(^|[\\s_-])(ad|ads|adv|advert|adsbygoogle|banner|promo|sponsor|sponsored|reklama|teaser|popunder)([\\s_0-9-]|$)/i;
      let n = 0, seen = 0;
      for (const el of document.querySelectorAll('[class],[id]')) {
        if (++seen > 6000 || n > 999) break;
        const cls = typeof el.className === 'string' ? el.className : '';
        if (!re.test(el.id + ' ' + cls)) continue;
        if (getComputedStyle(el).display === 'none') n++;
      }
      return n;
    })()
    """
}
