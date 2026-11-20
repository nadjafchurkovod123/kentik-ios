import WebKit

/// Компиляция списков в WKContentRuleListStore с кэшем по идентификатору.
///
/// Идентификатор содержит sha256 списка, поэтому уже скомпилированный список просто
/// находится в хранилище (lookUp) — повторная компиляция нужна только для новых версий.
/// JSON читается и распаковывается вне главного потока; сама компиляция у WebKit тоже
/// фоновая. Списки компилируются по одному, чтобы не держать в памяти несколько JSON сразу.
@MainActor
final class RuleListCompiler {

    struct Source {
        let identifier: String
        let name: String
        let load: @Sendable () throws -> String
    }

    struct Result {
        var lists: [WKContentRuleList] = []
        var compiledIdentifiers: [String] = []
        var failures: [(name: String, error: Error)] = []
        /// Сколько списков пришлось компилировать заново (не из кэша).
        var freshlyCompiled = 0
    }

    struct CompileError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let store: WKContentRuleListStore

    init(store: WKContentRuleListStore? = nil) {
        self.store = store ?? .default()
    }

    /// - Parameter progress: (номер, всего) — вызывается перед компиляцией, не взятой из кэша.
    func compile(_ sources: [Source], progress: ((Int, Int) -> Void)? = nil) async -> Result {
        var result = Result()
        for (index, source) in sources.enumerated() {
            if let cached = await lookUp(source.identifier) {
                result.lists.append(cached)
                result.compiledIdentifiers.append(source.identifier)
                continue
            }
            progress?(index + 1, sources.count)
            let started = Date()
            do {
                let loader = source.load
                let json = try await Task.detached(priority: .userInitiated) { try loader() }.value
                let list = try await compile(identifier: source.identifier, json: json)
                result.lists.append(list)
                result.compiledIdentifiers.append(source.identifier)
                result.freshlyCompiled += 1
                NSLog("[Kentik] список %@ скомпилирован за %.1f с", source.name, Date().timeIntervalSince(started))
            } catch {
                NSLog("[Kentik] список %@ не скомпилировался: %@", source.name, error.localizedDescription)
                result.failures.append((source.name, error))
            }
        }
        return result
    }

    /// Удаляет из хранилища наши списки, которых нет в keep (старые версии).
    func removeStale(keeping keep: Set<String>) {
        let store = self.store
        store.getAvailableContentRuleListIdentifiers { identifiers in
            for identifier in identifiers ?? []
            where identifier.hasPrefix(FilterListManifest.identifierPrefix) && !keep.contains(identifier) {
                store.removeContentRuleList(forIdentifier: identifier) { _ in }
            }
        }
    }

    private func lookUp(_ identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private func compile(identifier: String, json: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? CompileError(message: "WebKit не вернул список"))
                }
            }
        }
    }
}
