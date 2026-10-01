import AppKit
import ApplicationServices

/// Состояние активного поля ввода через Accessibility API.
/// Вызывать с фонового потока: приложение может отвечать до таймаута.
enum Selection {
    struct Snapshot {
        /// Длина выделения в редактируемом поле.
        var selectionLength = 0
        /// Выделенный текст (если его удалось прочитать).
        var selectedText: String?
        /// До 200 символов перед курсором (перед началом выделения), если поле редактируемое.
        var textBeforeCaret: String?
    }

    /// Не редактируемое поле (лог терминала, страница) — пустой снимок: печатать туда нельзя,
    /// иначе буквы сработают как горячие клавиши (Gmail и т.п.).
    static func snapshot(pid: pid_t?) -> Snapshot {
        var result = Snapshot()
        guard let element = focusedElement(pid: pid), isEditable(element),
              let range = selectedRange(element) else { return result }
        result.selectionLength = range.length
        if range.length > 0 {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
               let text = value as? String, !text.isEmpty {
                result.selectedText = text
            }
        }
        result.textBeforeCaret = text(element, before: range.location, limit: 200)
        return result
    }

    /// Длина выделения в активном редактируемом поле (0 — нет или не узнать).
    /// Автодополнение (Spotlight, адресная строка) выделяет подсказку после курсора:
    /// первый Backspace сотрёт её, а не букву. Отвечает быстро или никак — ждём не дольше 50 мс.
    static func focusedSelectionLength() -> Int {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        guard let element = copyElement(system, kAXFocusedUIElementAttribute, timeout: 0.05),
              isEditable(element), let range = selectedRange(element) else { return 0 }
        return range.length
    }

    /// Последнее слово и пробелы после него: ("ghbdtn ", 7). Через перевод строки не идём.
    static func lastWord(in text: String) -> (text: String, count: Int)? {
        let chars = Array(text)
        var end = chars.count
        while end > 0, chars[end - 1] == " " || chars[end - 1] == "\u{A0}" || chars[end - 1] == "\u{200B}" { end -= 1 }
        var start = end
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        guard start < end, end - start <= 64 else { return nil }
        return (String(chars[start...]), chars.count - start)
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func text(_ element: AXUIElement, before location: Int, limit: Int) -> String? {
        guard location >= 0 else { return nil }
        let start = max(0, location - limit)
        var range = CFRange(location: start, length: location - start)
        if let rangeValue = AXValueCreate(.cfRange, &range) {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                          rangeValue, &value) == .success,
               let text = value as? String {
                return text
            }
        }
        // Запасной путь — весь текст поля, если он не огромный.
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let count = count as? Int, count > 200_000 {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let full = value as? String else { return nil }
        let utf16 = full.utf16
        guard location <= utf16.count else { return nil }
        let from = utf16.index(utf16.startIndex, offsetBy: start)
        let to = utf16.index(utf16.startIndex, offsetBy: location)
        return String(utf16[from..<to])
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        for attribute in [kAXSelectedTextAttribute, kAXValueAttribute] {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success, settable.boolValue {
                return true
            }
        }
        // Текстовые области без права записи не берём: так выглядят и лог терминала, и консоль Xcode.
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let fieldRoles = [kAXTextFieldRole as String, kAXComboBoxRole as String, "AXSearchField"]
        return fieldRoles.contains(role as? String ?? "")
    }

    private static func focusedElement(pid: pid_t?) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        if let element = copyElement(system, kAXFocusedUIElementAttribute) { return element }
        // Некоторые приложения отвечают только через свой элемент.
        guard let pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        return copyElement(app, kAXFocusedUIElementAttribute)
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String,
                                    timeout: Float = 0.3) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let result = value as! AXUIElement
        AXUIElementSetMessagingTimeout(result, timeout)
        return result
    }
}
