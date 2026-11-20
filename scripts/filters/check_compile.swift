// Проверка перед публикацией списков: каждый список из manifest.json компилируется настоящим
// WebKit (WKContentRuleListStore на macOS). Список, который не компилируется, в релиз «lists»
// попадать не должен: приложение отказалось бы от всего ежедневного обновления.
//
// Сборка и запуск (CI, .github/workflows/filters.yml):
//   swiftc -O scripts/filters/check_compile.swift -o check_compile && ./check_compile build/lists
import Foundation
import WebKit

struct CheckError: Error, CustomStringConvertible {
    let description: String
}

/// Результат асинхронного вызова WebKit (обработчик приходит на главный поток).
final class Box {
    var done = false
    var error: Error?
}

func spin(until box: Box) {
    while !box.done {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

func run() throws -> Int32 {
    let arguments = CommandLine.arguments
    guard arguments.count == 2 else {
        print("использование: check_compile <папка с manifest.json>")
        return 2
    }
    let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
    guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
          let lists = manifest["lists"] as? [[String: Any]], !lists.isEmpty else {
        throw CheckError(description: "в манифесте нет списков")
    }
    let store: WKContentRuleListStore = WKContentRuleListStore.default()
    var failed: [String] = []
    for entry in lists {
        guard let file = entry["file"] as? String else { throw CheckError(description: "запись без file") }
        let packed = try Data(contentsOf: directory.appendingPathComponent(file))
        let raw = try (packed as NSData).decompressed(using: .zlib) as Data
        let json = String(decoding: raw, as: UTF8.self)
        let identifier = "kentik-check.\(file)"
        let started = Date()

        let compiled = Box()
        store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
            compiled.error = error ?? (list == nil ? CheckError(description: "WebKit не вернул список") : nil)
            compiled.done = true
        }
        spin(until: compiled)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        if let error = compiled.error {
            print("::error::\(file): не компилируется WebKit: \(error.localizedDescription)")
            failed.append(file)
        } else {
            print("  \(file): компилируется, \(entry["rules"] ?? "?") правил, \(seconds) с")
        }

        let removed = Box()
        store.removeContentRuleList(forIdentifier: identifier) { _ in removed.done = true }
        spin(until: removed)
    }
    if !failed.isEmpty {
        print("Не компилируются \(failed.count) из \(lists.count): \(failed.joined(separator: ", "))")
        return 1
    }
    print("Все списки компилируются WebKit: \(lists.count)")
    return 0
}

do {
    exit(try run())
} catch {
    print("::error::проверка списков: \(error)")
    exit(1)
}
