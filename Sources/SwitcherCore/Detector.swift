import Foundation

public enum Decision: Equatable {
    case keep       // слово набрано правильно (или сомнительно — не трогаем)
    case convert    // слово набрано не в той раскладке
    case undecided  // слово есть в обоих языках или из одной буквы: решит следующее слово
}

/// Решает, набрано ли слово не в той раскладке.
/// Частотные словари + системный спеллчекер, для незнакомых слов — триграммная модель.
public final class Detector {
    public private(set) var models: [Lang: LanguageModel] = [:]
    /// Нормализованное слово → место в частотном списке (1 — самое частое).
    public private(set) var ranks: [Lang: [String: Int]] = [:]
    /// Системная проверка орфографии (NSSpellChecker в приложении).
    public var spellCheck: ((String, Lang) -> Bool)?
    /// Системное исправление незнакомого слова (nil — нечего предложить).
    public var spellCorrection: ((String, Lang) -> String?)?

    /// Насколько (в log P на символ) альтернатива должна быть правдоподобнее набранного.
    public var margin = 1.0
    /// Минимальное правдоподобие альтернативы, чтобы менять незнакомое слово.
    public var minScore = -2.9
    /// То же, когда набранное вообще не похоже на слово (знаки внутри: "k.,k.").
    public var strongScore = -2.9
    /// Короче — по одной статистике не меняем.
    public var minLettersForModel = 4
    /// Слово знает только спеллчекер — считаем его редким.
    let spellOnlyRank = 1_000_000

    public init() {}

    /// Загружает список "слово частота" (по строке, самые частые сверху) для языка.
    public func load(_ lang: Lang, wordList: String, limit: Int = .max) {
        let model = LanguageModel(lang: lang)
        var map: [String: Int] = [:]
        var rank = 0
        for line in wordList.split(separator: "\n", omittingEmptySubsequences: true) {
            if rank >= limit { break }
            rank += 1
            let parts = line.split(separator: " ")
            guard let first = parts.first else { continue }
            let word = Detector.normalize(String(first))
            if map[word] == nil { map[word] = rank }
            let freq = parts.count > 1 ? Double(parts[1]) ?? 1 : 1
            model.add(word, weight: log(1 + freq))
        }
        model.finalize()
        models[lang] = model
        ranks[lang] = map
    }

    public static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    // MARK: - Разбор гипотезы

    struct Analysis {
        var core = ""          // без знаков препинания по краям
        var parts: [String] = []
        var letters = 0
        var clean = false      // только буквы языка (+ внутренние - и ')
        var hyphenated = false
        var apostrophe = false
        var mixedCase = false  // camelCase / iPhone / пРИВЕТ
    }

    public static func isLetter(_ ch: Character, _ lang: Lang) -> Bool {
        guard ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        switch lang {
        case .en: return (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
        case .ru: return (0x410...0x44F).contains(v) || v == 0x401 || v == 0x451
        }
    }

    /// Знаки, с которых слово не начинается / которыми не заканчивается.
    /// В EN-раскладке на этих клавишах русские буквы: ",sk" — это «был», а не слово "sk".
    static let badLeading: Set<Character> = [",", ".", ";", ":", "'", "[", "]", "{", "}", "`", "~", "§", "±", "<", ">"]
    static let badTrailing: Set<Character> = ["[", "{", "`", "~", "§", "±", "<", ">"]

    static func analyze(_ s: String, _ lang: Lang) -> Analysis {
        var a = Analysis()
        let chars = Array(s)
        var i = 0, j = chars.count
        while i < j, !chars[i].isLetter { i += 1 }
        while j > i, !chars[j - 1].isLetter { j -= 1 }
        guard i < j else { return a }
        a.core = String(chars[i..<j])

        var clean = !chars[..<i].contains(where: badLeading.contains) && !chars[j...].contains(where: badTrailing.contains)
        var part = ""
        for ch in chars[i..<j] {
            if isLetter(ch, lang) {
                a.letters += 1
                part.append(ch)
            } else if (ch == "-" || ch == "'" || ch == "’"), !part.isEmpty {
                if ch == "-" { a.hyphenated = true } else { a.apostrophe = true }
                a.parts.append(part)
                part = ""
            } else {
                clean = false
            }
        }
        if part.isEmpty { clean = false } else { a.parts.append(part) }
        a.clean = clean

        let letters = Array(a.core.filter(\.isLetter))
        let upper = letters.filter(\.isUppercase).count
        if upper > 0, upper < letters.count {
            // Допустимо «Привет» (заглавная первая) и «ПРивет» (Shift отпустили поздно). Остальное — смешанный регистр.
            a.mixedCase = !(upper == 1 && letters.first!.isUppercase) && !isStickyShift(letters)
        }
        return a
    }

    /// «ПРивет», "HEllo": Shift отпустили на букву позже. Не "TVs", "IDs", "URLs" — там после заглавных одна буква.
    public static func isStickyShift(_ letters: [Character]) -> Bool {
        letters.count >= 4 && letters[0].isUppercase && letters[1].isUppercase
            && letters.dropFirst(2).allSatisfy(\.isLowercase)
    }

    // MARK: - Словари

    /// Место слова в частотном списке; знакомое только спеллчекеру — редкое; nil — незнакомое.
    func rank(ofWord w: String, _ lang: Lang) -> Int? {
        if let r = ranks[lang]?[Detector.normalize(w)] { return r }
        return spellKnows(w, lang) ? spellOnlyRank : nil
    }

    /// Знает ли слово спеллчекер (с любым из привычных регистров).
    func spellKnows(_ w: String, _ lang: Lang) -> Bool {
        // Однобуквенные — только из списка ("a", "я"), спеллчекер знает любую букву.
        guard w.count > 1, let spell = spellCheck else { return false }
        let lower = w.lowercased()
        if spell(w, lang) { return true }
        if w == lower { return spell(lower.capitalized, lang) } // москва → Москва
        if w == w.uppercased() { return spell(lower, lang) || spell(lower.capitalized, lang) }
        return false
    }

    /// Английские сокращения с апострофом. Спеллчекер режет слово по ' и принимает любые
    /// огрызки ("v'r" из «мэк», "l'd" из «дэв»), поэтому такие слова проверяем по списку.
    static let contractions: Set<String> = Set("""
        i'm i'd i'll i've you're you've you'll you'd he's he'd he'll she's she'd she'll it's it'd it'll \
        we're we've we'll we'd they're they've they'll they'd that's that'll that'd who's who'd who'll \
        who've what's what'd what'll what're where's where'd when's why's how's how'd there's there'd \
        there'll here's let's isn't aren't wasn't weren't don't doesn't didn't won't wouldn't can't \
        couldn't shouldn't mustn't mightn't needn't hasn't haven't hadn't ain't o'clock y'all ma'am \
        could've would've should've might've must've
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    func rank(_ a: Analysis, _ lang: Lang) -> Int? {
        if a.hyphenated {
            // "кто-то", "из-за", "well-known": целиком в словаре или каждая часть знакома.
            if let r = ranks[lang]?[Detector.normalize(a.core)] { return r }
            guard a.parts.count > 1, a.parts.allSatisfy({ $0.count > 1 }) else { return nil }
            var worst = 0
            for part in a.parts {
                guard let r = rank(ofWord: part, lang) else { return nil }
                worst = max(worst, r)
            }
            return worst
        }
        if a.apostrophe {
            guard lang == .en else { return nil }
            let word = Detector.normalize(a.core).replacingOccurrences(of: "’", with: "'")
            if Detector.contractions.contains(word) { return 100 }
            // Притяжательное: "dog's", "John's".
            if a.parts.count == 2, a.parts[1].lowercased() == "s", a.parts[0].count > 1 {
                return rank(ofWord: a.parts[0], lang)
            }
            return nil
        }
        return rank(ofWord: a.core, lang)
    }

    func score(_ a: Analysis, _ lang: Lang) -> Double? {
        // "v'r" (из «мэк») — не слово, статистике по огрызкам верить нельзя.
        guard let model = models[lang], !a.apostrophe else { return nil }
        var sum = 0.0, weight = 0.0
        for part in a.parts {
            guard let s = model.score(Detector.normalize(part)) else { return nil }
            let w = Double(part.count + 1)
            sum += s * w
            weight += w
        }
        return weight > 0 ? sum / weight : nil
    }

    // MARK: - Решение

    /// Знакомо ли слово (со знаками по краям) языку.
    public func knows(_ word: String, _ lang: Lang) -> Bool {
        let a = Detector.analyze(word, lang)
        return a.clean && rank(a, lang) != nil
    }

    /// - Parameter context: язык предыдущего слова строки, если оно набрано верно и знакомо.
    public func decide(current: String, currentLang: Lang, alternative: String, alternativeLang: Lang,
                       context: Lang? = nil) -> Decision {
        let cur = Detector.analyze(current, currentLang)
        let alt = Detector.analyze(alternative, alternativeLang)
        guard alt.clean, !alt.mixedCase else { return .keep }

        if alt.letters == 1 {
            // «в», «я», "a" — настоящие слова: не трогаем и к следующей замене не цепляем ("в руддщ").
            // "z", "d" — не слова: решит следующее слово ("z ljvf" → «я дома»).
            guard cur.clean, cur.letters == 1 else { return .keep }
            return rank(cur, currentLang) == nil ? .undecided : .keep
        }
        let altRank = rank(alt, alternativeLang)

        guard cur.clean else {
            // Набранное — не слово (знаки препинания внутри): "k.,k." → «люблю».
            if altRank != nil { return .convert }
            guard alt.letters >= minLettersForModel, let sa = score(alt, alternativeLang) else { return .keep }
            return sa >= strongScore ? .convert : .keep
        }
        if cur.mixedCase { return .keep }
        // Набранное объясняет больше нажатий буквами: «фею», а не "at.".
        let curHasMoreLetters = cur.letters > alt.letters

        switch (rank(cur, currentLang), altRank) {
        case let (rc?, ra?):
            if curHasMoreLetters { return .keep }
            // Пишет на этом языке — спорное слово не трогаем: "React vs Vue". Но не когда набранное знает
            // только спеллчекер (часто лишь с заглавной: "Yt"), а вариант — из самых частых слов: "yt" → «не».
            if context == currentLang, rc < spellOnlyRank || ra > 100 { return .keep }
            if ra * 50 < rc { return .convert }  // "tot" → «ещё», "vs" → «мы»
            if rc * 3 < ra { return .keep }      // "here", а не «руку»
            return .undecided
        case (_?, nil):
            return .keep
        case (nil, _?):
            // "руддщб" → "hello," — да; незнакомое, но похожее на слово «фею» → "at." — нет.
            if curHasMoreLetters, let sc = score(cur, currentLang), sc >= minScore { return .keep }
            return .convert
        case (nil, nil):
            guard alt.letters >= minLettersForModel,
                  let sa = score(alt, alternativeLang),
                  let sc = score(cur, currentLang) else { return .keep }
            return sa - sc >= margin && sa >= minScore ? .convert : .keep
        }
    }
}
