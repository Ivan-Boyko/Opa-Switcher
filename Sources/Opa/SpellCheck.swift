import AppKit
import SwitcherCore

/// Системная проверка орфографии с ограничением по времени.
/// Спеллчекер — отдельный процесс: если он завис, перехват клавиатуры ждать его не должен.
final class SpellCheck {
    private let queue = DispatchQueue(label: "Opa.spell", qos: .userInteractive)
    private let checker = NSSpellChecker.shared
    private let timeout: TimeInterval = 0.05
    private var cache: [String: Bool] = [:]
    /// "" — системе нечего предложить.
    private var corrections: [String: String] = [:]
    private var pausedUntil: TimeInterval = 0
    private var lastUse: TimeInterval = 0
    /// Вызов, не уложившийся в 50 мс, ещё идёт: новые не ставим в очередь за ним.
    private let stuck = Flag()

    init() {
        warmUp()
    }

    /// Первый вызов после простоя (запуск, сон ночью) медленный: спеллчекер — отдельный процесс, его будят.
    /// Будим заранее — на первом нажатии, а не на пробеле после слова.
    func warmUpIfIdle() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastUse > 60 else { return }
        lastUse = now
        warmUp()
    }

    private func warmUp() {
        let checker = self.checker
        queue.async {
            for (word, lang) in [("warmup", "en"), ("прогрев", "ru")] {
                _ = checker.checkSpelling(of: word, startingAt: 0, language: lang, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
            }
        }
    }

    /// Вызывать с одного потока (перехвата). Не ответил за 50 мс — «не знаю»: обходимся словарями,
    /// пока зависший вызов не вернётся (и ещё 5 с).
    func isCorrect(_ word: String, _ lang: Lang) -> Bool {
        let key = "\(lang.rawValue):\(word)"
        if let cached = cache[key] { return cached }
        let checker = self.checker
        guard let ok = ask({
            checker.checkSpelling(of: word, startingAt: 0, language: lang.rawValue, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }) else { return false }
        if cache.count > 20_000 { cache.removeAll() }
        cache[key] = ok
        return ok
    }

    /// Как исправила бы слово система (nil — нечего предложить или не успела).
    func correction(_ word: String, _ lang: Lang) -> String? {
        let key = "\(lang.rawValue):\(word)"
        if let cached = corrections[key] { return cached.isEmpty ? nil : cached }
        let checker = self.checker
        guard let fixed = ask({
            checker.correction(forWordRange: NSRange(location: 0, length: (word as NSString).length), in: word,
                               language: lang.rawValue, inSpellDocumentWithTag: 0) ?? ""
        }) else { return nil }
        if corrections.count > 5_000 { corrections.removeAll() }
        corrections[key] = fixed
        return fixed.isEmpty ? nil : fixed
    }

    private func ask<T>(_ work: @escaping () -> T) -> T? {
        let now = ProcessInfo.processInfo.systemUptime
        lastUse = now
        guard now >= pausedUntil, !stuck.value else { return nil }
        let result = ResultBox<T>()
        queue.async { result.set(work()) }
        guard let value = result.wait(timeout) else {
            pausedUntil = now + 5
            stuck.value = true
            // Очередь последовательная: этот блок выполнится, когда зависший вызов вернётся.
            queue.async { [stuck] in stuck.value = false }
            log.error("Спеллчекер не ответил за \(Int(self.timeout * 1000)) мс, обхожусь без него, пока не ответит")
            return nil
        }
        return value
    }
}

private final class Flag {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class ResultBox<T> {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: T?

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
        semaphore.signal()
    }

    func wait(_ timeout: TimeInterval) -> T? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
