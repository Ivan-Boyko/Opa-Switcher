import Foundation

/// Настройки в UserDefaults.
final class Settings {
    private let defaults = UserDefaults.standard

    var autoSwitch: Bool {
        get { defaults.object(forKey: "autoSwitch") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoSwitch") }
    }

    /// По умолчанию выключено: жаргон и названия иногда принимаются за опечатки.
    var typoFix: Bool {
        get { defaults.object(forKey: "typoFix") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "typoFix") }
    }

    /// Сочетание клавиш вместо двойного Shift (или вместе с ним); nil — не задано.
    var hotkey: Hotkey? {
        get { Hotkey(stored: defaults.dictionary(forKey: "hotkey")) }
        set { defaults.set(newValue?.stored, forKey: "hotkey") }
    }

    var doubleShift: Bool {
        get { defaults.object(forKey: "doubleShift") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "doubleShift") }
    }

    /// Bundle ID приложений, где автопереключение и исправление опечаток выключены.
    var excludedApps: Set<String> {
        get { Set(defaults.stringArray(forKey: "excludedApps") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "excludedApps") }
    }

    /// Слова, автозамену или исправление которых пользователь откатил двойным Shift.
    var ignoredWords: Set<String> {
        get { Set(defaults.stringArray(forKey: "ignoredWords") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "ignoredWords") }
    }
}
