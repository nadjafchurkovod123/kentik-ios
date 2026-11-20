import WebKit

/// Защита от рекламных перенаправлений (касание плеера уводит вкладку на рекламу,
/// setTimeout → location.href, подмена ссылки в момент клика, iframe плеера меняет
/// top.location, бесконечные цепочки «нажмите, чтобы продолжить»).
///
/// Касание ссылки разрешает переход только на её собственный сайт. Переход главного фрейма
/// на ДРУГОЙ сайт отменяется (и показывается плашка «Открыть» — ошибка стоит одно касание),
/// если его начал не пользователь:
///  * скрипт или форма страницы (location.href, setTimeout, касание плеера не по ссылке) —
///    рекламные сети меняют домены каждый день, поэтому список хостов тут не нужен;
///  * скрипт подменил адрес ссылки, которой коснулись (переход не на её сайт);
///  * переход из iframe;
///  * серверное перенаправление на хост из списка рекламных (AdHosts), пятое и дальше
///    перенаправление за 10 секунд (цепочка) или возврат туда, где вкладка уже дважды была
///    за 15 секунд (петля).
/// Пропускаются: адреса, открытые самим приложением (адресная строка, «Открыть»), серверные
/// перенаправления (зеркала сайтов, сокращатели ссылок), переходы сразу после ссылки на
/// другой сайт (страница «переход по внешней ссылке») и входы через OAuth.
/// Если вернуть `.cancel`, Browser увеличит счётчик blockedRedirects вкладки.
@MainActor
final class RedirectGuard {

    static let shared = RedirectGuard()

    /// Сколько секунд после касания ссылки переход считается начатым пользователем.
    static let linkTapWindow: TimeInterval = 3
    /// Сколько секунд после касания ссылки живёт цепочка «ссылка → страница-переходник → сайт».
    static let linkChainWindow: TimeInterval = 10
    /// Сколько секунд живёт адрес, открытый самим приложением.
    static let appIntentWindow: TimeInterval = 15
    static let chainWindow: TimeInterval = 10
    static let chainLimit = 4
    static let loopWindow: TimeInterval = 15

    struct Request {
        var url: URL?
        var type: WKNavigationType
        /// Переход меняет главный фрейм вкладки.
        var targetsMainFrame: Bool
        /// Переход начат из главного фрейма (false — из iframe).
        var fromMainFrame: Bool
        /// Текущий адрес вкладки (откуда уходим).
        var pageURL: URL?
        /// Вкладка инкогнито (у неё свои временные выключатели сайтов).
        var incognito = false
        /// Серверное перенаправление (HTTP 3xx) уже идущей загрузки, а не новый переход.
        var isRedirect = false
    }

    enum Verdict: Equatable {
        case allow
        case cancel(reason: String)
    }

    var isShieldEnabled: @MainActor (_ host: String?, _ incognito: Bool) -> Bool = {
        ShieldController.shared.isEnabled(forHost: $0, incognito: $1)
    }
    var adHosts: AdHosts = .shared

    func decide(navigationAction: WKNavigationAction, tab: Tab) -> WKNavigationActionPolicy {
        let target = GuardFrames.targetFrame(of: navigationAction)
        var state = GuardState.shared.state(for: tab)
        let request = Request(
            url: navigationAction.request.url,
            type: navigationAction.navigationType,
            targetsMainFrame: target?.isMainFrame ?? false,
            fromMainFrame: GuardFrames.sourceFrame(of: navigationAction)?.isMainFrame ?? true,
            pageURL: tab.webView.url,
            incognito: tab.isIncognito,
            isRedirect: GuardFrames.isRedirect(navigationAction) ?? state.provisionalInProgress
        )
        guard request.targetsMainFrame else { return .allow }

        // Новая вкладка (target=_blank) наследует недавнее касание ссылки у открывателя.
        if state.lastLinkTapAt == nil, let opener = tab.opener {
            let openerState = GuardState.shared.state(for: opener)
            state.lastTapAt = openerState.lastTapAt
            state.lastLinkTapAt = openerState.lastLinkTapAt
            state.lastLinkURL = openerState.lastLinkURL
            state.lastLinkTapPageHost = openerState.lastLinkTapPageHost
        }
        let verdict = evaluate(request, state: &state, now: Date())
        GuardState.shared.update(tab) { $0 = state }

        switch verdict {
        case .allow:
            return .allow
        case .cancel(let reason):
            NSLog("[Kentik] переход заблокирован (%@): %@", reason, request.url?.absoluteString ?? "")
            let kind: BlockedNoticeBar.Kind = adHosts.contains(host: request.url?.host) ? .redirect : .siteRedirect
            BlockedNoticeBar.show(kind, url: request.url, on: tab)
            return .cancel
        }
    }

    /// Чистое решение; state обновляется (журнал автоматических переходов).
    func evaluate(_ request: Request, state: inout TabGuardState, now: Date) -> Verdict {
        guard request.targetsMainFrame, let url = request.url else { return .allow }
        let pageHost = request.pageURL?.host
        guard isShieldEnabled(pageHost, request.incognito) else { return .allow }

        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return .allow }
        let host = url.host

        if LoginHosts.contains(host) || LoginHosts.contains(pageHost) {
            return .allow
        }

        switch request.type {
        case .backForward, .reload:
            state.autoNavigations.removeAll()
            return .allow
        default:
            break
        }

        // Адрес открыло приложение (адресная строка, плитка, «Открыть» в плашке).
        if let intentURL = state.appIntentURL, let at = state.appIntentAt,
           now.timeIntervalSince(at) <= Self.appIntentWindow,
           Domain.clean(intentURL.host ?? "") == Domain.clean(host ?? "") {
            state.autoNavigations.removeAll()
            return .allow
        }

        // Касание ссылки разрешает переход только на её собственный сайт (адрес ссылки
        // запоминается в момент касания, до того как скрипт успеет его подменить).
        if let link = state.recentLinkURL(now, within: Self.linkTapWindow),
           let linkSite = Domain.registrable(link.host), linkSite == Domain.registrable(host) {
            state.autoNavigations.removeAll()
            return .allow
        }

        guard Domain.isCrossSite(pageHost, host) else { return .allow }

        if adHosts.contains(host: host) {
            return .cancel(reason: "реклама \(host ?? "")")
        }
        if !request.fromMainFrame {
            return .cancel(reason: "iframe уводит вкладку на \(host ?? "")")
        }
        if request.isRedirect || followsTappedLink(request, url: url, state: state, now: now) {
            return checkChain(url, state: &state, now: now)
        }
        // Скрипт или форма страницы уводит вкладку на другой сайт (касание плеера, таймер,
        // подменённая ссылка): отменяем; плашка «Открыть» вернёт переход одним касанием.
        if state.recentLinkURL(now, within: Self.linkTapWindow) != nil {
            return .cancel(reason: "ссылку подменили: переход не на её сайт")
        }
        if state.tappedRecently(now, within: Self.linkTapWindow) {
            return .cancel(reason: "переход на другой сайт после касания не по ссылке")
        }
        return .cancel(reason: "переход на другой сайт без касания")
    }

    /// Переход продолжает цепочку от касания ссылки: страница, куда увела ссылка на другой
    /// сайт, сразу переправляет дальше (сокращатель ссылок, «переход по внешней ссылке»), или
    /// ссылка / страница-переходник сами содержат адрес назначения (…/away?to=https://…).
    /// Внутренняя ссылка сайта такого права не даёт: иначе страница серии, открытая касанием,
    /// могла бы при загрузке увести вкладку на рекламу.
    private func followsTappedLink(_ request: Request, url: URL, state: TabGuardState, now: Date) -> Bool {
        guard let link = state.recentLinkURL(now, within: Self.linkChainWindow),
              let tapAt = state.lastLinkTapAt,
              let committed = state.lastCommitAt, committed >= tapAt,
              let pageURL = request.pageURL,
              Domain.registrable(pageURL.host) == Domain.registrable(link.host) else { return false }
        if Domain.isCrossSite(state.lastLinkTapPageHost, link.host) { return true }
        return Self.mentions(link, site: url.host) || Self.mentions(pageURL, site: url.host)
    }

    /// Цепочки и петли перенаправлений.
    private func checkChain(_ url: URL, state: inout TabGuardState, now: Date) -> Verdict {
        state.autoNavigations.removeAll { now.timeIntervalSince($0.at) > max(Self.chainWindow, Self.loopWindow) }
        let key = Self.loopKey(url)
        let recentChain = state.autoNavigations.filter { now.timeIntervalSince($0.at) <= Self.chainWindow }
        if recentChain.count >= Self.chainLimit {
            return .cancel(reason: "цепочка перенаправлений")
        }
        let visits = state.autoNavigations.filter { $0.key == key && now.timeIntervalSince($0.at) <= Self.loopWindow }
        if visits.count >= 2 {
            return .cancel(reason: "петля перенаправлений")
        }
        state.autoNavigations.append((at: now, key: key))
        return .allow
    }

    /// Есть ли в параметрах адреса ссылка на сайт `site` (?url=https%3A%2F%2Fsite…).
    static func mentions(_ url: URL, site: String?) -> Bool {
        guard let target = Domain.registrable(site),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return items.contains { item in
            guard let value = item.value, let candidate = URL(string: value),
                  let scheme = candidate.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
            return Domain.registrable(candidate.host) == target
        }
    }

    /// Ключ адреса для поиска петель: хост + путь, без запроса.
    static func loopKey(_ url: URL) -> String {
        Domain.clean(url.host ?? "") + url.path
    }

    // MARK: - Сигналы от приложения

    /// Вкладка открывает адрес по воле пользователя (адресная строка, закладка, «Открыть»).
    func noteAppNavigation(to url: URL, tab: Tab) {
        GuardState.shared.recordAppIntent(on: tab, url: url)
    }
}
