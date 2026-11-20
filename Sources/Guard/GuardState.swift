import Foundation

/// Что защита помнит об одной вкладке: недавние касания пользователя (их сообщает
/// скриплет из страницы), адреса, открытые самим приложением, и недавние автоматические
/// переходы (для поиска цепочек и петель перенаправлений).
struct TabGuardState {
    /// Последнее касание страницы (любой фрейм).
    var lastTapAt: Date?
    /// Последнее касание ссылки: когда и куда она ведёт.
    var lastLinkTapAt: Date?
    var lastLinkURL: URL?
    /// Хост страницы, на которой коснулись ссылки (отличает ссылку на другой сайт от внутренней).
    var lastLinkTapPageHost: String?
    /// Когда в главном фрейме вкладки последний раз открылась (commit) новая страница.
    var lastCommitAt: Date?
    /// Идёт загрузка главного фрейма, ещё без commit (для распознавания серверных
    /// перенаправлений, если WebKit не сообщает об этом сам).
    var provisionalInProgress = false
    /// Адрес, который открыло приложение (адресная строка, «Открыть» в плашке).
    var appIntentAt: Date?
    var appIntentURL: URL?
    /// Автоматические (без касания) переходы главного фрейма на другой сайт.
    var autoNavigations: [(at: Date, key: String)] = []

    func tappedRecently(_ now: Date, within window: TimeInterval) -> Bool {
        guard let at = lastTapAt else { return false }
        return now.timeIntervalSince(at) <= window
    }

    /// Ссылка, которой пользователь коснулся недавно (nil — касаний ссылок не было).
    func recentLinkURL(_ now: Date, within window: TimeInterval) -> URL? {
        guard let at = lastLinkTapAt, now.timeIntervalSince(at) <= window else { return nil }
        return lastLinkURL
    }
}

/// Хранилище состояния защиты по вкладкам. Состояние живёт, пока жива вкладка.
@MainActor
final class GuardState {

    static let shared = GuardState()

    private final class Entry {
        weak var tab: Tab?
        var state = TabGuardState()
        init(tab: Tab) { self.tab = tab }
    }

    private var entries: [UUID: Entry] = [:]

    func state(for tab: Tab) -> TabGuardState {
        entries[tab.id]?.state ?? TabGuardState()
    }

    func update(_ tab: Tab, _ change: (inout TabGuardState) -> Void) {
        let entry: Entry
        if let existing = entries[tab.id] {
            entry = existing
        } else {
            entry = Entry(tab: tab)
            entries[tab.id] = entry
            entries = entries.filter { $0.value.tab != nil }
        }
        change(&entry.state)
    }

    /// Пользователь коснулся страницы (link — адрес ссылки под пальцем, если была).
    func recordTap(on tab: Tab, link: URL?, at now: Date = Date()) {
        let pageHost = tab.host
        update(tab) { state in
            state.lastTapAt = now
            if let link {
                state.lastLinkTapAt = now
                state.lastLinkURL = link
                state.lastLinkTapPageHost = pageHost
            }
        }
    }

    /// Главный фрейм начал загрузку (started) или закончил её этап (commit, ошибка, конец).
    func recordProvisional(on tab: Tab, started: Bool) {
        update(tab) { $0.provisionalInProgress = started }
    }

    /// В главном фрейме открылась новая страница.
    func recordCommit(on tab: Tab, at now: Date = Date()) {
        update(tab) { state in
            state.lastCommitAt = now
            state.provisionalInProgress = false
        }
    }

    /// Приложение само открывает адрес во вкладке.
    func recordAppIntent(on tab: Tab, url: URL, at now: Date = Date()) {
        update(tab) { state in
            state.appIntentAt = now
            state.appIntentURL = url
            state.autoNavigations.removeAll()
        }
    }
}

/// Входы через OAuth и платёжные окна: их всплывающие окна и перенаправления не трогаем.
enum LoginHosts {

    static let domains: [String] = [
        "accounts.google.com", "accounts.youtube.com", "appleid.apple.com", "idmsa.apple.com",
        "vk.com", "vk.ru", "vkontakte.ru", "id.vk.com", "oauth.vk.com",
        "oauth.telegram.org", "login.microsoftonline.com", "login.live.com", "account.live.com",
        "github.com", "facebook.com", "x.com", "twitter.com", "discord.com", "id.twitch.tv",
        "steamcommunity.com", "login.steampowered.com", "login.mail.ru", "oauth.mail.ru",
        "account.mail.ru", "o2.mail.ru", "connect.ok.ru", "esia.gosuslugi.ru", "id.sber.ru",
        "id.tbank.ru", "id.tinkoff.ru", "id.mos.ru", "paypal.com", "checkout.stripe.com",
        "auth0.com", "okta.com", "login.yahoo.com", "appleid.cdn-apple.com",
    ]

    /// Яндекс живёт на многих доменах верхнего уровня (yandex.ru, yandex.com, yandex.kz…).
    private static let yandexPrefixes = ["passport.yandex.", "oauth.yandex.", "sso.yandex.", "id.yandex."]

    static func contains(_ host: String?) -> Bool {
        guard let host = host.map(Domain.clean), !host.isEmpty else { return false }
        if yandexPrefixes.contains(where: { host.hasPrefix($0) }) { return true }
        return Domain.host(host, matchesAnyOf: domains)
    }
}

/// Тестовый флаг защиты (только DEBUG): -KentikTestAdHosts host1,host2 — считать эти
/// хосты рекламными, чтобы UI-тесты проверяли перенаправления на фикстурах без сети.
enum GuardTestHooks {
    static var extraAdHosts: [String] {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-KentikTestAdHosts"), index + 1 < arguments.count else {
            return []
        }
        return arguments[index + 1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
#else
        return []
#endif
    }
}
