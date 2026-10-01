import AppKit

/// Текст из поля, которое не отдаёт его через Accessibility (VS Code, Chrome, Slack), — через буфер обмена.
/// Сначала ⌘C: если что-то выделено, это оно. Иначе ⌘⇧← и ⌘C — строка до курсора, а → снимает выделение,
/// и курсор остаётся где был. Буфер обмена потом возвращается как был.
enum ClipboardText {
    enum Result {
        case selection(String)
        case beforeCaret(String)
        case nothing
    }

    enum Shortcut {
        case copy
        case selectToLineStart
        case collapseRight
    }

    /// Терминалы: там ⌘⇧← и ⌘C значат другое.
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty",
        "co.zeit.hyper", "com.github.wez.wezterm", "org.tabby",
    ]

    /// Фоновый поток: ждёт, пока приложение скопирует. `send` отправляет сочетание клавиш.
    static func read(send: (Shortcut) -> Void) -> Result {
        let pasteboard = NSPasteboard.general
        let saved = save(pasteboard)
        defer { restore(saved, to: pasteboard) }

        var count = pasteboard.changeCount
        send(.copy)
        let copied = waitForChange(pasteboard, from: count, timeout: 0.2)
        if copied {
            count = pasteboard.changeCount
            // VS Code без выделения копирует всю строку с переводом строки — это не выделение.
            if let text = pasteboard.string(forType: .string), !text.isEmpty, !text.contains(where: \.isNewline) {
                return .selection(text)
            }
        }
        send(.selectToLineStart)
        send(.copy)
        // Не скопировалось — скорее всего, до курсора пусто и выделять было нечего. Стрелку тогда не жмём:
        // она сдвинула бы курсор.
        let copiedLine = waitForChange(pasteboard, from: count, timeout: 0.4)
        guard copiedLine else { return .nothing }
        let text = pasteboard.string(forType: .string)
        send(.collapseRight)
        guard let text, !text.isEmpty, !text.contains(where: \.isNewline) else { return .nothing }
        return .beforeCaret(text)
    }

    private static func waitForChange(_ pasteboard: NSPasteboard, from count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pasteboard.changeCount != count { return true }
            usleep(10_000)
        }
        return pasteboard.changeCount != count
    }

    /// Копия содержимого буфера обмена — чтобы вернуть его после.
    static func save(_ pasteboard: NSPasteboard = .general) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
