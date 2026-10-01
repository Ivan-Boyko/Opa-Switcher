import Foundation

/// Одно нажатие клавиши в текущей строке и символ, который оно сейчас дало в тексте.
public struct Keystroke: Equatable {
    /// Для символов, у которых нет клавиши в раскладках (эмодзи, тире), — только юникод.
    public static let unicodeOnly: UInt16 = 0xFFFF

    public var keyCode: UInt16
    public var mods: KeyMods
    /// Раскладка, в которой набран символ; nil — клавиша даёт одно и то же в обеих (пробел, цифры).
    public var lang: Lang?
    public var text: String
    /// Вставлен из буфера обмена, а не набран: автозамена такие слова не трогает.
    public var pasted = false

    public init(keyCode: UInt16, mods: KeyMods, lang: Lang?, text: String) {
        self.keyCode = keyCode
        self.mods = mods
        self.lang = lang
        self.text = text
    }
}

public struct KeyFlags {
    public var shift = false
    public var caps = false
    public var command = false
    public var control = false
    public var option = false
    public var function = false

    public init(shift: Bool = false, caps: Bool = false, command: Bool = false,
                control: Bool = false, option: Bool = false, function: Bool = false) {
        self.shift = shift
        self.caps = caps
        self.command = command
        self.control = control
        self.option = option
        self.function = function
    }

    public var mods: KeyMods { KeyMods(shift: shift, caps: caps) }
}

public enum KeyCode {
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let delete: UInt16 = 51
    public static let enter: UInt16 = 76
    public static let forwardDelete: UInt16 = 117
    public static let left: UInt16 = 123
    public static let right: UInt16 = 124
    public static let leftShift: UInt16 = 56
    public static let rightShift: UInt16 = 60
}

/// Куда движок отправляет правки текста.
public protocol EngineOutput: AnyObject {
    /// Удалить `count` символов перед курсором и набрать `keys`.
    func replace(deleting count: Int, with keys: [Keystroke])
    /// Сдвинуть курсор стрелками: + вправо, − влево.
    func moveCaret(by offset: Int)
    func switchLayout(to lang: Lang)
}

/// Помнит, что набрано в текущей строке, и исправляет раскладку:
/// автоматически (по пробелу/Enter/Tab) и по запросу (двойной Shift). По пробелу исправляет и опечатки.
public final class LineEngine {
    public var layouts: LayoutPair
    public let detector: Detector
    public weak var output: EngineOutput?

    public var autoSwitchEnabled = true
    public var typoFixEnabled = true
    /// Можно ли автоматически править текст прямо сейчас (например, приложение в исключениях).
    public var autoSwitchAllowed: () -> Bool = { true }
    /// Текущая раскладка системы — на случай, если у события нет символа.
    public var currentLang: () -> Lang? = { nil }
    /// Слова, которые пользователь запретил менять.
    public var isIgnored: (String) -> Bool = { _ in false }
    /// Пользователь откатил автозамену слова — запомнить.
    public var onAutoConversionUndone: (String) -> Void = { _ in }

    public private(set) var line: [Keystroke] = []
    /// Курсор внутри `line`: стрелки ←/→ двигают его, набор вставляет в него.
    public private(set) var caret = 0
    /// Меняется при каждом нажатии и сбросе: по нему видно, что строка изменилась.
    public private(set) var revision = 0
    /// Символ, который движок учёл для последнего нажатия (nil — клавиша не символьная).
    /// С ним повторяют нажатие, отложенное за нашими событиями, — чтобы в поле попало то же, что в буфере.
    public private(set) var lastKeyText: String?
    private var pendingStart: Int?
    /// Только что вставленный кусок — пока курсор сразу за ним и ничего не нажато.
    private var pasteRange: Range<Int>?
    /// Язык предыдущего слова строки, набранного верно.
    private var context: Lang?
    private var lastConversion: Conversion?
    private let typos: TypoCorrector
    private let maxLine = 400

    struct Conversion {
        var start: Int
        var before: [Keystroke]
        var after: [Keystroke]
        var langBefore: Lang
        var langAfter: Lang
        var autoWord: String?
    }

    public enum Verdict { case pass, swallow }

    public init(layouts: LayoutPair, detector: Detector) {
        self.layouts = layouts
        self.detector = detector
        typos = TypoCorrector(detector: detector)
    }

    public var text: String { line.map(\.text).joined() }

    public func reset() {
        revision &+= 1
        line.removeAll()
        caret = 0
        pendingStart = nil
        pasteRange = nil
        lastConversion = nil
        context = nil
    }

    /// ⌘V: вставленный текст становится частью строки — двойной Shift сможет его перевести.
    public func paste(_ text: String) {
        revision &+= 1
        lastConversion = nil
        pendingStart = nil
        pasteRange = nil
        guard !text.isEmpty, text.count <= 1000, !text.contains(where: \.isNewline) else { return reset() }
        var keys = keystrokes(for: text).keys
        for i in keys.indices { keys[i].pasted = true }
        let start = caret
        line.insert(contentsOf: keys, at: caret)
        caret += keys.count
        pasteRange = start..<caret
        if line.count > maxLine { reset() }
    }

    // MARK: - Ввод

    /// Нажатие клавиши пользователем. `.swallow` — событие нужно проглотить (движок перенабрал его сам).
    public func keyDown(keyCode: UInt16, flags: KeyFlags, chars: String) -> Verdict {
        revision &+= 1
        pasteRange = nil
        lastKeyText = nil
        if flags.command || flags.control {
            // Ctrl+Space / Ctrl+Opt+Space — смена раскладки, текст не трогает.
            if flags.control, !flags.command, keyCode == KeyCode.space { return .pass }
            reset()
            return .pass
        }
        if flags.option {
            reset()
            return .pass
        }

        switch keyCode {
        case KeyCode.delete:
            lastConversion = nil
            if caret > 0 {
                line.remove(at: caret - 1)
                caret -= 1
            }
            if let p = pendingStart, p >= caret { pendingStart = nil }
            return .pass

        case KeyCode.forwardDelete:
            lastConversion = nil
            if caret < line.count { line.remove(at: caret) }
            return .pass

        case KeyCode.left, KeyCode.right:
            let target = caret + (keyCode == KeyCode.left ? -1 : 1)
            // Со Shift — выделение; за пределами набранного — неизвестный текст. Не отслеживаем.
            guard !flags.shift, (0...line.count).contains(target) else {
                reset()
                return .pass
            }
            caret = target
            lastConversion = nil
            pendingStart = nil
            return .pass

        case KeyCode.returnKey, KeyCode.enter, KeyCode.tab:
            guard caret == line.count else {
                reset()
                return .pass
            }
            let text = keyCode == KeyCode.tab ? "\t" : "\r"
            let boundary = Keystroke(keyCode: keyCode, mods: flags.mods, lang: nil, text: text)
            // Одно слово перед Enter/Tab не трогаем: это может быть пароль или логин ("gfhjkm" — не «пароль»).
            let converted = autoConvertLastWord(boundary: boundary, keepBoundary: false, requireEarlierWord: true)
            reset()
            return converted ? .swallow : .pass

        case KeyCode.space:
            lastConversion = nil
            let space = Keystroke(keyCode: keyCode, mods: flags.mods, lang: nil, text: " ")
            // Автозамена — только в конце набранного: посреди текста слово может продолжаться дальше.
            // Опечатки — только здесь: Enter мог уже отправить сообщение, откатить исправление будет нельзя.
            if caret == line.count, autoConvertLastWord(boundary: space, keepBoundary: true, fixTypos: true) {
                return .swallow
            }
            insert(space)
            return .pass

        default:
            guard !flags.function, let key = classify(keyCode: keyCode, mods: flags.mods, chars: chars) else {
                reset()
                return .pass
            }
            lastConversion = nil
            insert(key)
            lastKeyText = key.text
            return .pass
        }
    }

    func classify(keyCode: UInt16, mods: KeyMods, chars: String) -> Keystroke? {
        let latin = layouts.latin.text(keyCode, mods)
        let cyrillic = layouts.cyrillic.text(keyCode, mods)
        guard isPrintable(latin) || isPrintable(cyrillic) else { return nil }
        var typed = chars
        // Символ — по раскладке, включённой в системе: по ней печатает приложение. Событие после смены
        // раскладки может ещё долго нести символ прежней (так бывает в VS Code), и слово не распознать.
        if let lang = currentLang() {
            let expected = layouts.layout(lang).text(keyCode, mods)
            if isPrintable(expected), expected.lowercased() != typed.lowercased() { typed = expected }
        }
        guard isPrintable(typed) else { return nil }

        func key(_ lang: Lang?) -> Keystroke { Keystroke(keyCode: keyCode, mods: mods, lang: lang, text: typed) }
        if typed == latin && typed == cyrillic { return key(nil) }
        if typed == latin { return key(.en) }
        if typed == cyrillic { return key(.ru) }
        // Caps Lock мог не попасть в флаги — сравним без регистра.
        let lower = typed.lowercased()
        if lower == latin.lowercased() { return key(.en) }
        if lower == cyrillic.lowercased() { return key(.ru) }
        return nil
    }

    private func insert(_ key: Keystroke) {
        line.insert(key, at: caret)
        caret += 1
        if caret < line.count { pendingStart = nil }
        if line.count > maxLine {
            let drop = line.count - maxLine / 2
            guard caret > drop else { return reset() }
            line.removeFirst(drop)
            caret -= drop
            pendingStart = nil
            lastConversion = nil
        }
    }

    // MARK: - Автопереключение

    /// Последнее слово строки (до пробела), если оно целиком набрано в одной раскладке.
    private func lastWord() -> (range: Range<Int>, lang: Lang)? {
        var start = line.count
        while start > 0, line[start - 1].text != " " { start -= 1 }
        guard start < line.count else { return nil }
        let langs = Set(line[start...].compactMap(\.lang))
        // Раскладку сменили посреди слова — часть букв из одной, часть из другой: не трогаем.
        guard langs.count == 1, let lang = langs.first else { return nil }
        return (start..<line.count, lang)
    }

    private func autoConvertLastWord(boundary: Keystroke, keepBoundary: Bool, requireEarlierWord: Bool = false,
                                     fixTypos: Bool = false) -> Bool {
        let typosOn = fixTypos && typoFixEnabled
        guard autoSwitchEnabled || typosOn, autoSwitchAllowed(), let (range, lang) = lastWord() else { return false }
        if requireEarlierWord, !line[..<range.lowerBound].contains(where: { $0.text != " " }) { return false }
        // Слова с цифрами (пароли, версии, идентификаторы) и вставленные — не трогаем.
        if line[range].contains(where: { $0.pasted || $0.text.contains(where: \.isNumber) }) {
            pendingStart = nil
            return false
        }
        let target = lang.other
        let current = line[range].map(\.text).joined()
        let alternative = line[range].map { convert($0, to: target).text }.joined()
        if isIgnored(Detector.normalize(current)) {
            pendingStart = nil
            return false
        }
        var decision = Decision.keep
        if autoSwitchEnabled {
            decision = detector.decide(current: current, currentLang: lang, alternative: alternative,
                                       alternativeLang: target, context: context)
        }
        switch decision {
        case .keep:
            pendingStart = nil
            if typosOn, let fixed = fixStickyShift(Array(line[range]), lang) {
                retype(from: range.lowerBound, with: fixed, langBefore: lang, langAfter: lang,
                       boundary: boundary, keepBoundary: keepBoundary, autoWord: current)
                return true
            }
            if detector.knows(current, lang) {
                context = lang
                return false
            }
            guard typosOn, let fixed = fixTypo(Array(line[range]), lang) else { return false }
            retype(from: range.lowerBound, with: fixed, langBefore: lang, langAfter: lang,
                   boundary: boundary, keepBoundary: keepBoundary, autoWord: current)
            return true
        case .undecided:
            if pendingStart == nil { pendingStart = range.lowerBound }
            return false
        case .convert:
            var start = range.lowerBound
            // Короткие/спорные слова перед этим — тоже из неверной раскладки: "z ljvf" → "я дома".
            if let p = pendingStart, p < start, line[p..<start].allSatisfy({ $0.lang == nil || $0.lang == lang }) {
                start = p
            }
            pendingStart = nil
            var after = line[start..<caret].map { convert($0, to: target) }
            // Shift, отпущенный поздно, правим при любом переводе: "GHbdtn" → «Привет», а не «ПРивет».
            // Опечатку — если они включены: "cgfc,j" → «спасбо» → «спасибо».
            let word = range.lowerBound - start
            if let fixed = fixStickyShift(Array(after[word...]), target)
                ?? (typosOn ? fixTypo(Array(after[word...]), target) : nil) {
                after.replaceSubrange(word..., with: fixed)
            }
            retype(from: start, with: after, langBefore: lang, langAfter: target,
                   boundary: boundary, keepBoundary: keepBoundary, autoWord: current)
            return true
        }
    }

    /// «ПРивет» → «Привет»: Shift отпустили на букву позже. Только для знакомых слов.
    private func fixStickyShift(_ keys: [Keystroke], _ lang: Lang) -> [Keystroke]? {
        let letters = keys.indices.filter { keys[$0].text.count == 1 && Detector.isLetter(keys[$0].text.first!, lang) }
        guard Detector.isStickyShift(letters.map { keys[$0].text.first! }) else { return nil }
        var fixed = keys
        let second = letters[1]
        fixed[second].mods.shift = false
        fixed[second].text = layouts.layout(lang).text(fixed[second].keyCode, fixed[second].mods)
        guard fixed[second].text == keys[second].text.lowercased(),
              detector.knows(fixed.map(\.text).joined(), lang) else { return nil }
        return fixed
    }

    /// Слово с исправленной опечаткой (знаки по краям остаются как были) или nil.
    private func fixTypo(_ keys: [Keystroke], _ lang: Lang) -> [Keystroke]? {
        func isLetter(_ key: Keystroke) -> Bool { key.text.count == 1 && Detector.isLetter(key.text.first!, lang) }
        guard let first = keys.firstIndex(where: isLetter), let last = keys.lastIndex(where: isLetter),
              keys[first...last].allSatisfy(isLetter) else { return nil }
        let word = keys[first...last].map(\.text).joined()
        guard let fix = typos.fix(word, lang, layout: layouts.layout(lang)) else { return nil }
        return Array(keys[..<first]) + keystrokes(for: fix.word).keys + Array(keys[(last + 1)...])
    }

    // MARK: - Конвертация

    func convert(_ key: Keystroke, to target: Lang) -> Keystroke {
        guard let lang = key.lang, lang != target else { return key }
        let text = layouts.layout(target).text(key.keyCode, key.mods)
        guard isPrintable(text) else { return key }
        var result = key
        result.lang = target
        result.text = text
        return result
    }

    /// Переводит `line[start..<caret]` (курсор стоит в конце этого куска).
    private func apply(from start: Int, to target: Lang, boundary: Keystroke?, keepBoundary: Bool, autoWord: String?) {
        retype(from: start, with: line[start..<caret].map { convert($0, to: target) }, langBefore: target.other,
               langAfter: target, boundary: boundary, keepBoundary: keepBoundary, autoWord: autoWord)
    }

    /// Заменяет `line[start..<caret]` на `after`: стирает и печатает только то, что отличается.
    private func retype(from start: Int, with after: [Keystroke], langBefore: Lang, langAfter: Lang,
                        boundary: Keystroke?, keepBoundary: Bool, autoWord: String?) {
        let end = caret
        var before = Array(line[start..<end])
        var after = after
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix].text == after[prefix].text { prefix += 1 }
        let deleteCount = before[prefix...].reduce(0) { $0 + $1.text.count }
        var typed = Array(after[prefix...])
        let boundaryAfter = boundary.map { convert($0, to: langAfter) }
        if let boundaryAfter { typed.append(boundaryAfter) }

        output?.replace(deleting: deleteCount, with: typed)
        if langAfter != langBefore { output?.switchLayout(to: langAfter) }
        context = langAfter

        line.replaceSubrange(start..<end, with: after)
        caret = start + after.count
        if keepBoundary, let boundary, let boundaryAfter {
            before.append(boundary)
            after.append(boundaryAfter)
            line.insert(boundaryAfter, at: caret)
            caret += 1
        }
        lastConversion = Conversion(start: start, before: before, after: after,
                                    langBefore: langBefore, langAfter: langAfter, autoWord: autoWord)
    }

    // MARK: - Двойной Shift

    /// Текст для сравнения с полем: браузеры отдают неразрывные пробелы и служебные символы
    /// (упоминания, пустые узлы) там, где у нас обычные пробелы или ничего.
    public static func comparable(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xA0, 0x202F, 0x2007: result.append(" ")
            case 0xFFFC, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF: continue
            default: result.append(scalar)
            }
        }
        return String(result)
    }

    /// Двойной Shift по тому, что набрано: откат последней замены, иначе перевод слова у курсора.
    /// - Parameter beforeCaret: текст перед курсором из Accessibility (nil — неизвестно).
    ///   Если буфер с ним расходится (автозамена, клик), ничего не делаем — пусть решает вызывающий.
    /// - Returns: false — по буферу переводить нечего или ему нельзя верить.
    @discardableResult
    public func doubleShift(beforeCaret: String?) -> Bool {
        func matches(_ keys: ArraySlice<Keystroke>) -> Bool {
            guard let beforeCaret else { return true }
            return LineEngine.comparable(beforeCaret).hasSuffix(LineEngine.comparable(keys.map(\.text).joined()))
        }

        if let c = lastConversion, c.start + c.after.count == caret, matches(line[c.start..<caret]) {
            var prefix = 0
            while prefix < min(c.after.count, c.before.count), c.after[prefix].text == c.before[prefix].text {
                prefix += 1
            }
            let deleteCount = c.after[prefix...].reduce(0) { $0 + $1.text.count }
            output?.replace(deleting: deleteCount, with: Array(c.before[prefix...]))
            if c.langBefore != c.langAfter { output?.switchLayout(to: c.langBefore) }
            line.replaceSubrange(c.start..<caret, with: c.before)
            caret = c.start + c.before.count
            context = c.langBefore
            if let word = c.autoWord { onAutoConversionUndone(Detector.normalize(word)) }
            lastConversion = Conversion(start: c.start, before: c.after, after: c.before,
                                        langBefore: c.langAfter, langAfter: c.langBefore, autoWord: nil)
            pendingStart = nil
            return true
        }

        // Сразу после вставки — весь вставленный кусок.
        if let r = pasteRange, r.upperBound == caret, matches(line[r]),
           let lang = line[r].last(where: { $0.lang != nil })?.lang {
            pasteRange = nil
            pendingStart = nil
            apply(from: r.lowerBound, to: lang.other, boundary: nil, keepBoundary: false, autoWord: nil)
            return true
        }

        // Слово у курсора. Курсор в слове или сразу за ним — всё слово (курсор уйдёт в его конец);
        // за пробелами — предыдущее слово вместе с пробелами.
        var start = caret, end = caret
        if caret > 0, line[caret - 1].text != " " {
            while end < line.count, line[end].text != " " { end += 1 }
        } else {
            while start > 0, line[start - 1].text == " " { start -= 1 }
        }
        let wordEnd = start
        while start > 0, line[start - 1].text != " " { start -= 1 }
        guard start < max(wordEnd, end), matches(line[start..<caret]),
              let lang = line[start..<max(caret, end)].last(where: { $0.lang != nil })?.lang else { return false }
        // Отложенные однобуквенные слова перед ним — из той же неверной раскладки: "d ujhjlt" → «в городе».
        if let p = pendingStart, p < start, line[p..<start].allSatisfy({ $0.lang == nil || $0.lang == lang }),
           matches(line[p..<caret]) {
            start = p
        }
        if end > caret {
            output?.moveCaret(by: end - caret)
            caret = end
        }
        pendingStart = nil
        apply(from: start, to: lang.other, boundary: nil, keepBoundary: false, autoWord: nil)
        return true
    }

    /// Переводит текст, который уже стоит перед курсором (или выделен): стирает `deleting` символов
    /// и печатает его в другой раскладке. Язык каждого символа — по алфавиту, знаки — как у соседней буквы.
    @discardableResult
    public func convertText(_ text: String, deleting: Int) -> Bool {
        guard !text.isEmpty, text.count <= 2000, !text.contains(where: \.isNewline) else { return false }
        let (originals, source) = keystrokes(for: text)
        guard let source else { return false }
        let target = source.other
        let keys = originals.map { convert($0, to: target) }
        output?.replace(deleting: deleting, with: keys)
        output?.switchLayout(to: target)
        line = keys
        caret = keys.count
        pendingStart = nil
        pasteRange = nil
        context = target
        // Повторный двойной Shift вернёт текст как был.
        lastConversion = Conversion(start: 0, before: originals, after: keys,
                                    langBefore: source, langAfter: target, autoWord: nil)
        return true
    }

    /// Нажатия, которыми набирается готовый текст. Язык буквы — по алфавиту, знака — как у соседней буквы.
    /// `source` — язык большинства букв (nil — букв нет).
    func keystrokes(for text: String) -> (keys: [Keystroke], source: Lang?) {
        let chars = Array(text)
        var langs: [Lang?] = chars.map { ch in
            if Detector.isLetter(ch, .en) { return .en }
            if Detector.isLetter(ch, .ru) { return .ru }
            return nil
        }
        let en = langs.filter { $0 == .en }.count
        let ru = langs.filter { $0 == .ru }.count
        let source: Lang? = en + ru == 0 ? nil : (en > ru ? .en : (ru > en ? .ru : (currentLang() ?? .en)))

        var last: Lang?
        for i in langs.indices {
            if let l = langs[i] { last = l } else { langs[i] = last }
        }
        if let firstLetter = langs.first(where: { $0 != nil }) ?? nil {
            for i in langs.indices where langs[i] == nil { langs[i] = firstLetter }
        }

        var keys: [Keystroke] = []
        for (ch, lang) in zip(chars, langs) {
            let s = String(ch)
            guard let lang, let key = layouts.layout(lang).key(for: ch) else {
                keys.append(Keystroke(keyCode: Keystroke.unicodeOnly, mods: KeyMods(), lang: nil, text: s))
                continue
            }
            let same = layouts.layout(lang.other).text(key.keyCode, key.mods) == s
            keys.append(Keystroke(keyCode: key.keyCode, mods: key.mods, lang: same ? nil : lang, text: s))
        }
        return (keys, source)
    }
}

/// Распознаёт двойное нажатие Shift (без других клавиш между).
public final class DoubleShiftDetector {
    public var maxPress: TimeInterval = 0.35
    public var maxGap: TimeInterval = 0.4
    private var pressedAt: TimeInterval?
    private var releasedAt: TimeInterval?

    public init() {}

    /// Shift нажат/отпущен. true — второе короткое нажатие подряд.
    public func shift(down: Bool, at time: TimeInterval) -> Bool {
        if down {
            if let r = releasedAt, time - r > maxGap { releasedAt = nil }
            pressedAt = time
            return false
        }
        guard let p = pressedAt, time - p <= maxPress else {
            interrupt()
            return false
        }
        pressedAt = nil
        if releasedAt != nil {
            releasedAt = nil
            return true
        }
        releasedAt = time
        return false
    }

    /// Любая другая клавиша, модификатор или клик.
    public func interrupt() {
        pressedAt = nil
        releasedAt = nil
    }
}
