import AppKit
import SwitcherCore

/// Сочетание клавиш, которым переводится слово или выделение — то же, что двойной Shift.
struct Hotkey: Equatable {
    var keyCode: UInt16
    /// Только ⌃ ⌥ ⇧ ⌘.
    var modifiers: CGEventFlags

    static let modifierMask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    static let functionKeyNumbers: [UInt16: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
    ]
    /// Заняты системой: Spotlight, смена раскладки, переключение приложений.
    static let reserved = [
        Hotkey(keyCode: KeyCode.space, modifiers: .maskCommand),
        Hotkey(keyCode: KeyCode.space, modifiers: .maskControl),
        Hotkey(keyCode: KeyCode.space, modifiers: [.maskControl, .maskAlternate]),
        Hotkey(keyCode: KeyCode.tab, modifiers: .maskCommand),
    ]

    init(keyCode: UInt16, modifiers: CGEventFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Hotkey.modifierMask)
    }

    func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        keyCode == self.keyCode && flags.intersection(Hotkey.modifierMask) == modifiers
    }

    /// Почему такое сочетание не подходит; nil — подходит.
    var problem: String? {
        if modifiers.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty,
           Hotkey.functionKeyNumbers[keyCode] == nil {
            return "Нужен ⌘, ⌃ или ⌥ — иначе сочетание мешало бы набору. Или клавиша F1–F20."
        }
        if Hotkey.reserved.contains(self) { return "Это сочетание занято системой." }
        return nil
    }

    /// «⌃⌥Z», «⇧F5». Буквы — как на клавише в латинской раскладке.
    func title(layout: KeyboardLayout?) -> String {
        var title = ""
        if modifiers.contains(.maskControl) { title += "⌃" }
        if modifiers.contains(.maskAlternate) { title += "⌥" }
        if modifiers.contains(.maskShift) { title += "⇧" }
        if modifiers.contains(.maskCommand) { title += "⌘" }
        return title + keyName(layout: layout)
    }

    private func keyName(layout: KeyboardLayout?) -> String {
        let special: [UInt16: String] = [
            KeyCode.space: "Пробел", KeyCode.returnKey: "↩", KeyCode.enter: "⌤", KeyCode.tab: "⇥",
            KeyCode.delete: "⌫", KeyCode.forwardDelete: "⌦", 53: "⎋", KeyCode.left: "←", KeyCode.right: "→",
            125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        ]
        if let name = special[keyCode] { return name }
        if let number = Hotkey.functionKeyNumbers[keyCode] { return "F\(number)" }
        let text = layout?.text(keyCode, KeyMods()) ?? ""
        return isPrintable(text) ? text.uppercased() : "#\(keyCode)"
    }

    // MARK: - Хранение

    var stored: [String: Int] { ["keyCode": Int(keyCode), "modifiers": Int(modifiers.rawValue)] }

    init?(stored: [String: Any]?) {
        guard let code = stored?["keyCode"] as? Int, let mods = stored?["modifiers"] as? Int else { return nil }
        self.init(keyCode: UInt16(truncatingIfNeeded: code), modifiers: CGEventFlags(rawValue: UInt64(mods)))
    }
}
