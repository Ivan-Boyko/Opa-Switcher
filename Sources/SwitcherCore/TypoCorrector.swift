import Foundation

/// Исправляет опечатки быстрого набора в незнакомых словах: две буквы местами, пропущенная буква,
/// лишняя (задвоенная или с соседней клавиши) буква, соседняя клавиша. Первую букву не меняет.
/// Исправляет только в настоящее слово (есть в частотном списке и его знает спеллчекер)
/// и только когда вариант один.
public final class TypoCorrector {
    public enum Kind: String {
        case swap = "перестановка"
        case missing = "пропуск"
        case extra = "лишняя"
        case neighbor = "соседняя клавиша"
        /// Перепутанная или лишняя гласная ("превет", "definately") — только если так же исправляет система.
        case vowel = "гласная"
    }

    public struct Candidate: Equatable {
        public let word: String
        public let rank: Int
        public let kind: Kind
    }

    public struct Candidates {
        /// Самые частые первыми.
        public let list: [Candidate]
        /// Что предлагает системная проверка орфографии.
        public let system: String?
        /// Место набранного слова в частотном списке, если оно там есть: частая ошибка ("untill") или сленг.
        public let typedRank: Int?
    }

    public struct Fix: Equatable {
        public let word: String
        public let kind: Kind
    }

    let detector: Detector
    /// Второй вариант должен встречаться хотя бы во столько раз реже первого, иначе — спорно, не трогаем.
    public var ambiguity = 10
    /// Система исправляет в другое знакомое слово — не трогаем. Кроме вариантов не реже `trustedRank`.
    public var systemVeto = true
    public var trustedRank = 300
    /// Слово из списка, которое спеллчекер не знает, исправляем, только если вариант во столько раз частотнее.
    public var misspellingRatio = 8
    /// Слово с заглавной часто оказывается именем — исправляем только в самые частые слова.
    public var capitalizedMaxRank = 5_000
    /// Пятибуквенные: пропуск, соседняя клавиша и гласная — только в слова не реже этого места.
    public var fiveLetterMaxRank = 5_000
    /// Соседняя клавиша и гласная в длинных словах.
    public var looseMaxRank = 20_000

    private var neighborCache: [String: [Character: [Character]]] = [:]

    static let alphabet: [Lang: [Character]] = [
        .en: Array("abcdefghijklmnopqrstuvwxyz"),
        .ru: Array("абвгдежзийклмнопрстуфхцчшщъыьэюя"),
    ]
    static let vowels: [Lang: Set<Character>] = [.en: Set("aeiouy"), .ru: Set("аеиоуыэюя")]

    public init(detector: Detector) {
        self.detector = detector
    }

    /// Исправленное слово (регистр первой буквы сохраняется) или nil — слово знакомое, вариантов нет или спорно.
    /// - Parameter word: только буквы языка, без знаков.
    public func fix(_ word: String, _ lang: Lang, layout: KeyboardLayout) -> Fix? {
        guard let found = candidates(word, lang, layout: layout), let best = found.list.first else { return nil }
        let list = found.list, system = found.system
        // Система исправляет в другое знакомое слово ("таска" → «маска») — спорно.
        if systemVeto, best.rank > trustedRank, let system, detector.ranks[lang]?[system] != nil,
           !list.contains(where: { $0.word == system }) {
            return nil
        }
        // Похожие по частоте: "жизн" — «жизнь» или «жизни»? Неверная замена хуже опечатки: её не видно.
        if list.count > 1, list[1].rank < best.rank * ambiguity { return nil }
        if let typedRank = found.typedRank {
            // Слово пишут часто, но спеллчекер его не знает: ошибка ("untill") или сленг («ваще»).
            // Короткие такие — чаще названия и сокращения ("info"), их не трогаем.
            guard word.count >= 5, best.kind != .neighbor, best.kind != .vowel,
                  best.rank * misspellingRatio <= typedRank, system == best.word else { return nil }
        }
        var result = best.word
        if word.first?.isUppercase == true {
            guard best.rank <= capitalizedMaxRank else { return nil }
            result = result.prefix(1).uppercased() + result.dropFirst()
        }
        return Fix(word: result, kind: best.kind)
    }

    /// Варианты исправления. nil — слово не берём: знакомое, короткое, со знаками или смешанным регистром.
    public func candidates(_ word: String, _ lang: Lang, layout: KeyboardLayout) -> Candidates? {
        let chars = Array(word)
        let n = chars.count
        guard n >= 3, n <= 24, chars.allSatisfy({ Detector.isLetter($0, lang) }) else { return nil }
        // «слово» и «Слово»; АББРЕВИАТУРЫ, CamelCase и пРИВЕТ не трогаем.
        let upper = chars.filter(\.isUppercase).count
        guard upper == 0 || (upper == 1 && chars[0].isUppercase) else { return nil }
        // Без спеллчекера (или пока он не отвечает) не понять, настоящее ли слово, — не трогаем.
        guard let spell = detector.spellCheck, let ranks = detector.ranks[lang],
              let alphabet = TypoCorrector.alphabet[lang], !detector.spellKnows(word, lang) else { return nil }

        let w = Array(Detector.normalize(word))
        var found: [String: Candidate] = [:]
        func consider(_ c: [Character], _ kind: Kind) {
            let s = String(c)
            guard found[s] == nil, let r = ranks[s], r <= maxRank(kind, n) else { return }
            found[s] = Candidate(word: s, rank: r, kind: kind)
        }
        let near = neighbors(layout, lang)
        func isNear(_ a: Character, _ b: Character?) -> Bool {
            guard let b else { return false }
            return a == b || near[a]?.contains(b) == true
        }

        // Две буквы местами: "првиет" → «привет», "teh" → "the".
        for i in 0..<(n - 1) where w[i] != w[i + 1] {
            var c = w
            c.swapAt(i, i + 1)
            consider(c, .swap)
        }
        // Пропущенная буква: "спасбо" → «спасибо». Перед первой буквой не вставляем.
        for i in 1...n {
            for a in alphabet {
                var c = w
                c.insert(a, at: i)
                consider(c, .missing)
            }
        }
        // Лишняя буква: задвоенная или с соседней клавиши ("приввет", "привкет" → «привет»).
        for i in 0..<n {
            let prev: Character? = i > 0 ? w[i - 1] : nil
            let next: Character? = i + 1 < n ? w[i + 1] : nil
            guard i > 0 ? isNear(w[i], prev) || isNear(w[i], next) : w[i] == next else { continue }
            var c = w
            c.remove(at: i)
            consider(c, .extra)
        }
        // Соседняя клавиша: "привкт" → «привет».
        for i in 1..<n {
            for b in near[w[i]] ?? [] {
                var c = w
                c[i] = b
                consider(c, .neighbor)
            }
        }

        var system: String?
        if let suggestion = detector.spellCorrection?(word, lang) {
            let s = Detector.normalize(suggestion)
            if s != String(w) {
                system = s
                if found[s] == nil, let r = ranks[s], r <= maxRank(.vowel, n),
                   TypoCorrector.isVowelSlip(w, Array(s), lang) {
                    found[s] = Candidate(word: s, rank: r, kind: .vowel)
                }
            }
        }
        // Только настоящие слова: в списке из субтитров есть и ошибки ("seperate"), и имена ("marcos").
        let list = found.values.filter { spell($0.word, lang) }.sorted { ($0.rank, $0.word) < ($1.rank, $1.word) }
        return Candidates(list: list, system: system, typedRank: ranks[String(w)])
    }

    /// Чем короче слово, тем больше у него «соседей» в словаре — короткие исправляем только в частые слова.
    /// Соседняя клавиша и гласная дают больше всего ложных вариантов ("фигме" → «фирме») — тоже только в частые.
    func maxRank(_ kind: Kind, _ n: Int) -> Int {
        switch (n, kind) {
        case (...3, .swap): return 300
        case (...3, _): return 0
        case (4, .swap): return 20_000
        case (4, .missing): return 2_000
        case (4, _): return 0
        case (5, .missing), (5, .neighbor), (5, .vowel): return fiveLetterMaxRank
        case (_, .neighbor), (_, .vowel): return looseMaxRank
        default: return .max
        }
    }

    /// Одна гласная заменена другой или лишняя гласная, не первой буквой: "превет" → «привет», "arguement" → "argument".
    static func isVowelSlip(_ w: [Character], _ s: [Character], _ lang: Lang) -> Bool {
        guard let vowels = vowels[lang] else { return false }
        if w.count == s.count {
            let diff = w.indices.filter { w[$0] != s[$0] }
            guard diff.count == 1, let i = diff.first, i > 0 else { return false }
            return vowels.contains(w[i]) && vowels.contains(s[i])
        }
        guard w.count == s.count + 1,
              let i = w.indices.first(where: { $0 >= s.count || w[$0] != s[$0] }), i > 0, vowels.contains(w[i]) else {
            return false
        }
        var c = w
        c.remove(at: i)
        return c == s
    }

    // MARK: - Клавиатура

    /// Центры клавиш по кодам (раскладка ANSI): ряд и x в ширинах клавиши.
    static let keyPositions: [UInt16: (row: Int, x: Double)] = {
        let rows: [(x: Double, codes: [UInt16])] = [
            (0.5, [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]),  // ` 1 2 … - =
            (2.0, [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42]),  // q w e … [ ] \
            (2.25, [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39]),               // a s d … ; '
            (2.75, [6, 7, 8, 9, 11, 45, 46, 43, 47, 44]),                 // z x c … . /
        ]
        var map: [UInt16: (row: Int, x: Double)] = [:]
        for (row, line) in rows.enumerated() {
            for (i, code) in line.codes.enumerated() { map[code] = (row, line.x + Double(i)) }
        }
        return map
    }()

    /// Буквы на соседних клавишах: в ряду — слева и справа, в соседних рядах — со сдвигом до ¾ клавиши.
    public func neighbors(_ layout: KeyboardLayout, _ lang: Lang) -> [Character: [Character]] {
        if let cached = neighborCache[layout.id] { return cached }
        var positions: [Character: (row: Int, x: Double)] = [:]
        for ch in TypoCorrector.alphabet[lang] ?? [] {
            if let key = layout.key(for: ch), !key.mods.shift, let p = TypoCorrector.keyPositions[key.keyCode] {
                positions[ch] = p
            }
        }
        var result: [Character: [Character]] = [:]
        for (a, pa) in positions {
            result[a] = positions.filter { b, pb in
                guard b != a else { return false }
                let dx = abs(pa.x - pb.x)
                switch abs(pa.row - pb.row) {
                case 0: return dx < 1.01
                case 1: return dx < 0.76
                default: return false
                }
            }.map(\.key).sorted()
        }
        neighborCache[layout.id] = result
        return result
    }
}
