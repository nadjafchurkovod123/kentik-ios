import XCTest
import UIKit

/// Канал к DiagProbe приложения (только DEBUG): папка на диске Mac, которую симулятор видит
/// напрямую. Тест пишет команды cmd-<n>.json, приложение отвечает res-<n>.json и каждую
/// секунду обновляет state.json. CI выкладывает папку /tmp/kentik-diag артефактом.
final class Diag {

    static let root = URL(fileURLWithPath: "/tmp/kentik-diag", isDirectory: true)

    let dir: URL
    private var next = 1

    init(_ name: String) {
        dir = Diag.root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    var environment: [String: String] { ["KENTIK_DIAG_DIR": dir.path] }

    /// Отправить команду и дождаться ответа.
    @discardableResult
    func send(_ command: [String: Any], timeout: TimeInterval = 25) -> [String: Any]? {
        let id = next
        next += 1
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return nil }
        let tmp = dir.appendingPathComponent(".pending-\(id).json")
        let file = dir.appendingPathComponent("cmd-\(id).json")
        try? data.write(to: tmp)
        try? FileManager.default.moveItem(at: tmp, to: file)
        let result = dir.appendingPathComponent("res-\(id).json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: result),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                return object
            }
            usleep(200_000)
        }
        return nil
    }

    /// Выполнить JavaScript во фреймах ("main", "all", "video", "url:<часть адреса>").
    /// Результат — значения по фреймам (строки, числа, словари).
    @discardableResult
    func eval(_ js: String, frames: String = "main", timeout: TimeInterval = 25) -> [Any] {
        guard let result = send(["op": "eval", "js": js, "frames": frames], timeout: timeout),
              let results = result["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { $0["value"] }
    }

    /// Первая строка-результат из главного фрейма.
    func evalString(_ js: String, frames: String = "main") -> String {
        (eval(js, frames: frames).first as? String) ?? ""
    }

    func state() -> [String: Any] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("state.json")),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return object
    }

    /// Сохранить текущее состояние рядом (для артефакта) под меткой.
    func snapshotState(_ label: String) {
        if let state = send(["op": "state"]),
           let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("\(label).state.json"))
        }
    }

    func note(_ label: String, _ object: Any) {
        let wrapped: Any = JSONSerialization.isValidJSONObject(object) ? object : ["value": String(describing: object)]
        if let data = try? JSONSerialization.data(withJSONObject: wrapped, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("\(label).json"))
        }
    }

    /// Фреймы из последнего состояния.
    func frames() -> [[String: Any]] {
        (state()["frames"] as? [[String: Any]]) ?? []
    }

    /// Видео во всех фреймах (из последнего состояния).
    func videos() -> [[String: Any]] {
        frames().flatMap { ($0["vids"] as? [[String: Any]]) ?? [] }
    }

    /// Хоть одно видео идёт (не на паузе, время больше нуля, есть кадр).
    func isVideoPlaying() -> Bool {
        videos().contains { v in
            (v["paused"] as? Bool) == false && ((v["t"] as? Double) ?? 0) > 0.3 && ((v["w"] as? Int) ?? 0) > 0
        }
    }

    func waitFor(_ timeout: TimeInterval, poll: TimeInterval = 1, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(useconds_t(poll * 1_000_000))
        }
        return condition()
    }
}

/// Простая оценка снимка экрана: доля «не чёрных» пикселей и разница двух снимков.
enum Pixels {
    struct Stats { let lit: Double; let colorful: Double }

    private static func rgba(_ image: UIImage, width: Int = 90, height: Int = 196) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// lit — доля пикселей ярче почти-чёрного; colorful — доля насыщенных (картинка видео).
    static func stats(_ image: UIImage) -> Stats {
        guard let px = rgba(image) else { return Stats(lit: 0, colorful: 0) }
        var lit = 0, colorful = 0, total = 0
        var i = 0
        while i < px.count {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            let lum = (299 * r + 587 * g + 114 * b) / 1000
            if lum > 40 { lit += 1 }
            if max(r, g, b) - min(r, g, b) > 60 && lum > 40 { colorful += 1 }
            total += 1
            i += 4
        }
        return Stats(lit: Double(lit) / Double(max(total, 1)), colorful: Double(colorful) / Double(max(total, 1)))
    }

    /// Средняя разница двух снимков (0…255): картинка меняется — рисуется.
    static func difference(_ a: UIImage, _ b: UIImage) -> Double {
        guard let x = rgba(a), let y = rgba(b) else { return 0 }
        var sum = 0
        for i in 0..<min(x.count, y.count) where i % 4 != 3 {
            sum += abs(Int(x[i]) - Int(y[i]))
        }
        return Double(sum) / Double(max(x.count * 3 / 4, 1))
    }
}

extension XCTestCase {
    /// Снимок всего экрана (в том числе окна «на весь экран» WebKit), приложенный к тесту.
    @MainActor
    @discardableResult
    func attachScreen(_ name: String) -> UIImage {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(data: shot.pngRepresentation, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return shot.image
    }
}
