import WebKit

/// Защита от рекламных перенаправлений (касание плеера уводит вкладку на рекламу,
/// setTimeout → location.href, iframe плеера меняет top.location, бесконечные цепочки
/// «нажмите, чтобы продолжить»).
///
/// Отменяются только переходы главного фрейма, которые начал не пользователь:
///  * на другой сайт из списка рекламных/вредоносных хостов (AdHosts);
///  * из iframe на другой сайт (iframe плеера меняет адрес всей вкладки);
///  * пятый и дальше автоматический переход на другой сайт за 10 секунд (цепочка);
///  * автоматический возврат на адрес, где вкладка уже дважды была за 15 секунд (петля).
/// Входы через OAuth (Google, Apple, VK, Яндекс, Telegram и т. п.) не трогаются.
/// Если вернуть `.cancel`, Browser увеличит счётчик blockedRedirects вкладки.
@MainActor
final class RedirectGuard {

    static let shared = RedirectGuard()

    /// Сколько секунд после касания ссылки переход считается начатым пользователем.
    static let linkTapWindow: TimeInterval = 3
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
    }

    enum Verdict: Equatable {
        case allow
        case cancel(reason: String)
    }

    var isShieldEnabled: @MainActor (String?) -> Bool = { ShieldController.shared.isEnabled(forHost: $0) }
    var adHosts: AdHosts = .shared

    func decide(navigationAction: WKNavigationAction, tab: Tab) -> WKNavigationActionPolicy {
        let target = GuardFrames.targetFrame(of: navigationAction)
        let request = Request(
            url: navigationAction.request.url,
            type: navigationAction.navigationType,
            targetsMainFrame: target?.isMainFrame ?? false,
            fromMainFrame: GuardFrames.sourceFrame(of: navigationAction)?.isMainFrame ?? true,
            pageURL: tab.webView.url
        )
        guard request.targetsMainFrame else { return .allow }

        var state = GuardState.shared.state(for: tab)
        // Новая вкладка (target=_blank) наследует недавнее касание ссылки у открывателя.
        if state.lastLinkTapAt == nil, let opener = tab.opener {
            let openerState = GuardState.shared.state(for: opener)
            state.lastTapAt = openerState.lastTapAt
            state.lastLinkTapAt = openerState.lastLinkTapAt
            state.lastLinkURL = openerState.lastLinkURL
        }
        let verdict = evaluate(request, state: &state, now: Date())
        GuardState.shared.update(tab) { $0 = state }

        switch verdict {
        case .allow:
            return .allow
        case .cancel(let reason):
            NSLog("[Kentik] переход заблокирован (%@): %@", reason, request.url?.absoluteString ?? "")
            BlockedNoticeBar.show(.redirect, url: request.url, on: tab)
            return .cancel
        }
    }

    /// Чистое решение; state обновляется (журнал автоматических переходов).
    func evaluate(_ request: Request, state: inout TabGuardState, now: Date) -> Verdict {
        guard request.targetsMainFrame, let url = request.url else { return .allow }
        let pageHost = request.pageURL?.host
        guard isShieldEnabled(pageHost) else { return .allow }

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

        if isUserInitiated(request, url: url, state: state, now: now) {
            state.autoNavigations.removeAll()
            return .allow
        }

        let crossSite = Domain.isCrossSite(pageHost, host)
        guard crossSite else { return .allow }

        if adHosts.contains(host: host) {
            return .cancel(reason: "реклама \(host ?? "")")
        }
        if !request.fromMainFrame {
            return .cancel(reason: "iframe уводит вкладку на \(host ?? "")")
        }

        // Цепочки и петли автоматических переходов.
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

    /// Переход начал пользователь: коснулся ссылки (на тот же сайт, если это рекламный
    /// хост), отправил форму после касания или открыл адрес из приложения.
    private func isUserInitiated(_ request: Request, url: URL, state: TabGuardState, now: Date) -> Bool {
        if let intentURL = state.appIntentURL, let at = state.appIntentAt,
           now.timeIntervalSince(at) <= Self.appIntentWindow,
           Domain.clean(intentURL.host ?? "") == Domain.clean(url.host ?? "") {
            return true
        }
        if let link = state.recentLinkURL(now, within: Self.linkTapWindow) {
            // Касание ссылки разрешает переход на её сайт. На рекламный хост — только если
            // вела туда сама ссылка, а не скрипт, перехвативший касание.
            if adHosts.contains(host: url.host) {
                return Domain.registrable(link.host) == Domain.registrable(url.host)
            }
            return true
        }
        if request.type == .formSubmitted || request.type == .formResubmitted {
            return state.tappedRecently(now, within: Self.linkTapWindow)
        }
        return false
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
