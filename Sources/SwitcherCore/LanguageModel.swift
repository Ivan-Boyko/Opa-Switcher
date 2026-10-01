import Foundation

/// Буквенная триграммная модель языка: насколько «похоже на слово» данная строка.
public final class LanguageModel {
    public let lang: Lang
    private let symbols: [Character: Int]
    private let size: Int
    private var tri: [Double]
    private var bi: [Double]
    private var uni: [Double]
    private var triContext: [Double]
    private var biContext: [Double]
    private var total = 0.0
    private var logp: [Float] = []

    public static let alphabets: [Lang: String] = [
        .en: "abcdefghijklmnopqrstuvwxyz",
        .ru: "абвгдежзийклмнопрстуфхцчшщъыьэюя",
    ]

    public init(lang: Lang) {
        self.lang = lang
        var symbols: [Character: Int] = [:]
        for (i, ch) in LanguageModel.alphabets[lang]!.enumerated() { symbols[ch] = i + 1 }
        self.symbols = symbols
        size = symbols.count + 1 // 0 — граница слова
        tri = Array(repeating: 0, count: size * size * size)
        bi = Array(repeating: 0, count: size * size)
        uni = Array(repeating: 0, count: size)
        triContext = Array(repeating: 0, count: size * size)
        biContext = Array(repeating: 0, count: size)
    }

    private func indices(_ word: String) -> [Int]? {
        var result = [0, 0]
        for ch in word {
            guard let i = symbols[ch] else { return nil }
            result.append(i)
        }
        result.append(0)
        return result
    }

    /// Добавляет нормализованное слово (строчные, ё → е) в статистику.
    public func add(_ word: String, weight: Double = 1) {
        guard let idx = indices(word) else { return }
        for i in 2..<idx.count {
            let a = idx[i - 2], b = idx[i - 1], c = idx[i]
            tri[(a * size + b) * size + c] += weight
            triContext[a * size + b] += weight
            bi[b * size + c] += weight
            biContext[b] += weight
            uni[c] += weight
            total += weight
        }
    }

    /// Пересчитывает таблицу логарифмов вероятностей (интерполяция 3-2-1-грамм).
    public func finalize(l3: Double = 0.6, l2: Double = 0.3, l1: Double = 0.1) {
        logp = Array(repeating: 0, count: size * size * size)
        for a in 0..<size {
            for b in 0..<size {
                for c in 0..<size {
                    let p1 = (uni[c] + 1) / (total + Double(size))
                    let p2 = biContext[b] > 0 ? bi[b * size + c] / biContext[b] : p1
                    let ctx = triContext[a * size + b]
                    let p3 = ctx > 0 ? tri[(a * size + b) * size + c] / ctx : p2
                    logp[(a * size + b) * size + c] = Float(log(l3 * p3 + l2 * p2 + l1 * p1))
                }
            }
        }
    }

    /// Средний log P на символ (чем ближе к нулю, тем «роднее» слово). nil — чужие символы.
    public func score(_ word: String) -> Double? {
        guard !logp.isEmpty, let idx = indices(word), idx.count > 3 else { return nil }
        var sum = 0.0
        for i in 2..<idx.count {
            sum += Double(logp[(idx[i - 2] * size + idx[i - 1]) * size + idx[i]])
        }
        return sum / Double(idx.count - 2)
    }
}
