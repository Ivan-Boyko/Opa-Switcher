import AppKit
import SwitcherCore

/// Окно «Сочетание клавиш»: записывает сочетание, которым переводить слово или выделение.
final class HotkeyWindow: NSObject, NSWindowDelegate {
    /// Сочетание задано или убрано (nil).
    var onChange: (Hotkey?) -> Void = { _ in }
    /// Идёт запись — перехват не должен срабатывать на нажатия.
    var onRecording: (Bool) -> Void = { _ in }
    var onClose: () -> Void = {}

    private let window: NSWindow
    private let field = NSButton()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let clear = NSButton()
    private let layout: KeyboardLayout?
    private var hotkey: Hotkey?
    private var monitor: Any?

    init(hotkey: Hotkey?, layout: KeyboardLayout?) {
        self.hotkey = hotkey
        self.layout = layout
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 170), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Сочетание клавиш"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let label = NSTextField(wrappingLabelWithString:
            "Переводит слово перед курсором или выделение в другую раскладку — то же, что двойной Shift.")
        field.bezelStyle = .rounded
        field.target = self
        field.action = #selector(startRecording)
        field.font = .systemFont(ofSize: 15, weight: .medium)
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        clear.title = "Убрать"
        clear.bezelStyle = .rounded
        clear.target = self
        clear.action = #selector(removeHotkey)
        let done = NSButton(title: "Готово", target: self, action: #selector(close))
        done.keyEquivalent = "\r"

        let buttons = NSStackView(views: [clear, done])
        let stack = NSStackView(views: [label, field, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 220),
            label.widthAnchor.constraint(equalToConstant: 360),
            hint.widthAnchor.constraint(equalToConstant: 360),
        ])
        refresh()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        field.title = hotkey?.title(layout: layout) ?? "Задать сочетание"
        hint.stringValue = hotkey == nil ? "Нажмите кнопку, затем сочетание, например ⌃⌥Z или F13." : ""
        clear.isEnabled = hotkey != nil
    }

    @objc private func startRecording() {
        guard monitor == nil else { return }
        field.title = "Нажмите сочетание…"
        hint.stringValue = "⎋ — отмена"
        onRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        let candidate = Hotkey(keyCode: event.keyCode, modifiers: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
        if candidate.modifiers.isEmpty, event.keyCode == 53 { return stopRecording() }
        if let problem = candidate.problem {
            hint.stringValue = problem
            return
        }
        hotkey = candidate
        onChange(candidate)
        stopRecording()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if monitor != nil { onRecording(false) }
        monitor = nil
        refresh()
    }

    @objc private func removeHotkey() {
        stopRecording()
        hotkey = nil
        onChange(nil)
        refresh()
    }

    @objc private func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
        onClose()
    }
}
