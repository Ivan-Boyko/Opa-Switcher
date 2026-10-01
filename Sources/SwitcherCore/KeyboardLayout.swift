import Carbon
import Foundation

/// Язык раскладки. `en` — латиница, `ru` — кириллица.
public enum Lang: String, CaseIterable {
    case en, ru

    public var other: Lang { self == .en ? .ru : .en }
}

/// Состояние модификаторов, влияющих на символ клавиши.
public struct KeyMods: Hashable {
    public var shift: Bool
    public var caps: Bool

    public init(shift: Bool = false, caps: Bool = false) {
        self.shift = shift
        self.caps = caps
    }

    var index: Int { (shift ? 1 : 0) | (caps ? 2 : 0) }
}

/// Таблица «код клавиши + модификаторы → символ» для одной раскладки.
public final class KeyboardLayout {
    public let id: String
    public let name: String
    public let lang: Lang
    public let source: TISInputSource?

    /// table[keyCode][mods.index]
    private let table: [[String]]
    private var reverse: [Character: (keyCode: UInt16, mods: KeyMods)] = [:]

    public init(id: String, name: String, lang: Lang, source: TISInputSource?, table: [[String]]) {
        self.id = id
        self.name = name
        self.lang = lang
        self.source = source
        self.table = table
        // Обратная карта: сначала без модификаторов, потом с Shift — чтобы предпочитать простые нажатия.
        // Цифровой блок не берём (в «Русской – ПК» его «,» дала бы "." вместо "?"),
        // клавишу § (10) — в последнюю очередь: «ё» ↔ "`", а не "§".
        let codes = (0..<table.count).filter { !(65...92).contains($0) && $0 != 10 } + (table.count > 10 ? [10] : [])
        for modsIndex in [0, 1] {
            for code in codes {
                let s = table[code][modsIndex]
                guard s.count == 1, let ch = s.first, isPrintable(s), reverse[ch] == nil else { continue }
                reverse[ch] = (UInt16(code), KeyMods(shift: modsIndex == 1))
            }
        }
    }

    public convenience init?(source: TISInputSource, lang: Lang) {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var table = Array(repeating: Array(repeating: "", count: 4), count: 128)
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in 0..<128 {
                for modsIndex in 0..<4 {
                    var modifiers: UInt32 = 0
                    if modsIndex & 1 != 0 { modifiers |= UInt32(shiftKey >> 8) }
                    if modsIndex & 2 != 0 { modifiers |= UInt32(alphaLock >> 8) }
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers,
                                                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                                &deadKeyState, chars.count, &length, &chars)
                    if status == noErr {
                        table[code][modsIndex] = String(utf16CodeUnits: chars, count: length)
                    }
                }
            }
        }
        self.init(id: source.stringProperty(kTISPropertyInputSourceID) ?? "?",
                  name: source.stringProperty(kTISPropertyLocalizedName) ?? "?",
                  lang: lang, source: source, table: table)
    }

    /// Символ, который даёт клавиша в этой раскладке ("" если клавиши нет).
    public func text(_ keyCode: UInt16, _ mods: KeyMods) -> String {
        guard Int(keyCode) < table.count else { return "" }
        return table[Int(keyCode)][mods.index]
    }

    /// Какой клавишей набирается символ в этой раскладке.
    public func key(for ch: Character) -> (keyCode: UInt16, mods: KeyMods)? {
        reverse[ch]
    }

    /// Короткое имя для строки меню.
    public var shortName: String { lang.rawValue.uppercased() }
}

/// Пара раскладок, между которыми переключаемся.
public struct LayoutPair {
    public let latin: KeyboardLayout
    public let cyrillic: KeyboardLayout

    public init(latin: KeyboardLayout, cyrillic: KeyboardLayout) {
        self.latin = latin
        self.cyrillic = cyrillic
    }

    public func layout(_ lang: Lang) -> KeyboardLayout { lang == .en ? latin : cyrillic }

    public func lang(ofSourceID id: String) -> Lang? {
        if id == latin.id { return .en }
        if id == cyrillic.id { return .ru }
        return nil
    }

    /// Находит среди включённых раскладок латинскую QWERTY (en) и русскую ЙЦУКЕН (ru).
    public static func discover() -> LayoutPair? {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        // "ru"/"en" заявляют и украинская, и сербская, и корейская — проверяем сами буквы на клавишах.
        var latin: (layout: KeyboardLayout, score: Int)?
        var cyrillic: (layout: KeyboardLayout, score: Int)?
        for source in list {
            let langs = source.languages
            if langs.contains("ru"), let layout = KeyboardLayout(source: source, lang: .ru),
               layout.text(0, KeyMods()) == "ф", layout.text(1, KeyMods()) == "ы" {
                let score = langs.first == "ru" ? 2 : 1
                if score > cyrillic?.score ?? 0 { cyrillic = (layout, score) }
            } else if langs.contains("en"), let layout = KeyboardLayout(source: source, lang: .en),
                      layout.text(0, KeyMods()) == "a", layout.text(12, KeyMods()) == "q", layout.text(6, KeyMods()) == "z" {
                let score = langs.first == "en" ? 2 : 1
                if score > latin?.score ?? 0 { latin = (layout, score) }
            }
        }
        guard let latin, let cyrillic else { return nil }
        return LayoutPair(latin: latin.layout, cyrillic: cyrillic.layout)
    }

    public static func currentSourceID() -> String? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue().stringProperty(kTISPropertyInputSourceID)
    }

    public var currentLang: Lang? {
        LayoutPair.currentSourceID().flatMap(lang(ofSourceID:))
    }

    @discardableResult
    public func select(_ lang: Lang) -> OSStatus {
        guard let source = layout(lang).source else { return OSStatus(paramErr) }
        return TISSelectInputSource(source)
    }
}

extension TISInputSource {
    func stringProperty(_ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(self, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    var languages: [String] {
        guard let ptr = TISGetInputSourceProperty(self, kTISPropertyInputSourceLanguages) else { return [] }
        return (Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String]) ?? []
    }
}

/// true, если строка — видимый символ (не управляющий, не функциональная клавиша).
public func isPrintable(_ s: String) -> Bool {
    guard !s.isEmpty else { return false }
    for scalar in s.unicodeScalars {
        let v = scalar.value
        if v < 0x20 || v == 0x7F || (0xF700...0xF8FF).contains(v) { return false }
    }
    return true
}
