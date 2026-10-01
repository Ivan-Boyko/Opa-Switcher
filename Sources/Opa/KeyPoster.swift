import CoreGraphics
import Foundation
import SwitcherCore

/// Печатает исправления синтетическими нажатиями: Backspace × N, затем символы.
///
/// Реальное нажатие, пришедшее, пока наши события ещё в пути, могло встать в очередь
/// раньше них. Такие нажатия перехватчик отдаёт в `replay` — они уходят следом за нашими.
final class KeyPoster: EngineOutput {
    /// Метка своих событий, чтобы перехватчик их пропускал.
    static let marker: Int64 = 0x4C53_5754

    var layouts: LayoutPair
    /// Смена раскладки: её делает приложение на главном потоке и потом зовёт `layoutSwitched()`.
    var onSwitchLayout: (Lang) -> Void = { _ in }
    private let source: CGEventSource?
    /// Наши события, которые ещё не вернулись через перехватчик.
    private var inFlight = 0
    private var lastProgress: TimeInterval = 0
    /// Раскладку попросили сменить, а система ещё не сменила: нажатия этого промежутка повторяем
    /// с символом новой раскладки, иначе они достались бы приложению в старой.
    private var switchRequestedAt: TimeInterval?

    init(layouts: LayoutPair) {
        self.layouts = layouts
        source = CGEventSource(stateID: .privateState)
        // Иначе система на 0.25 с глушит реальные нажатия после каждого нашего события —
        // печатаешь быстро, а доходят только первая и последняя буквы.
        source?.localEventsSuppressionInterval = 0
        let permitAll: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source?.setLocalEventsFilterDuringSuppressionState(permitAll, state: .eventSuppressionStateSuppressionInterval)
        source?.setLocalEventsFilterDuringSuppressionState(permitAll, state: .eventSuppressionStateRemoteMouseDrag)
    }

    /// Есть ли наши события, до которых приложение ещё не дошло.
    func isBusy() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        // Событие потерялось (перехват выключался) — не держим очередь вечно.
        if inFlight > 0, now - lastProgress > 0.5 {
            log.error("Свои события не вернулись (\(self.inFlight)), сбрасываю очередь")
            inFlight = 0
        }
        if let requested = switchRequestedAt, now - requested > 0.5 {
            log.error("Раскладка не сменилась за 0,5 с, нажатия снова идут напрямую")
            switchRequestedAt = nil
        }
        return inFlight > 0 || switchRequestedAt != nil
    }

    /// Система сменила раскладку (или сказала, какая включена) — нажатия снова идут напрямую.
    func layoutSwitched() {
        switchRequestedAt = nil
    }

    /// Перехватчик увидел наше событие.
    func ownEventArrived() {
        if inFlight > 0 { inFlight -= 1 }
        lastProgress = ProcessInfo.processInfo.systemUptime
    }

    func reset() {
        inFlight = 0
        switchRequestedAt = nil
    }

    /// Переотправляет реальное нажатие за нашими.
    /// - Parameter text: символ, который учёл движок; nil — какой был в событии.
    func replay(_ event: CGEvent, text: String?) {
        // Новое событие от нашего источника, а не копия аппаратного: копия несла бы системный источник
        // с глушением реальных нажатий после отправки.
        let keyCode = CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        guard let copy = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: event.type == .keyDown) else {
            return
        }
        copy.flags = event.flags
        // Символ фиксируем: раскладка могла смениться, а движок уже учёл именно этот.
        copy.setTypedString(text ?? event.typedString)
        copy.setIntegerValueField(.keyboardEventAutorepeat, value: event.getIntegerValueField(.keyboardEventAutorepeat))
        send(copy)
    }

    func replace(deleting count: Int, with keys: [Keystroke]) {
        // За курсором выделена подсказка автодополнения — первый Backspace уйдёт на неё.
        let extra = count > 0 && Selection.focusedSelectionLength() > 0 ? 1 : 0
        for _ in 0..<(count + extra) {
            post(keyCode: KeyCode.delete, text: nil)
        }
        for key in keys {
            let special = key.keyCode == KeyCode.returnKey || key.keyCode == KeyCode.enter || key.keyCode == KeyCode.tab
            let code = key.keyCode == Keystroke.unicodeOnly ? 0 : key.keyCode
            // Символ задаём явно — он не зависит от того, успела ли смениться раскладка.
            post(keyCode: code, text: special ? nil : key.text, flags: key.mods.shift ? .maskShift : [])
        }
    }

    /// Сочетание для чтения поля через буфер обмена.
    func post(_ shortcut: ClipboardText.Shortcut) {
        let arrow: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]
        switch shortcut {
        // Без явного символа: с ним приложение принимает нажатие за набор текста, а не за ⌘C.
        case .copy: post(keyCode: 8, text: nil, flags: .maskCommand)
        case .selectToLineStart: post(keyCode: KeyCode.left, text: nil, flags: arrow.union([.maskCommand, .maskShift]))
        case .collapseRight: post(keyCode: KeyCode.right, text: nil, flags: arrow)
        }
    }

    func moveCaret(by offset: Int) {
        let code = offset > 0 ? KeyCode.right : KeyCode.left
        for _ in 0..<abs(offset) {
            post(keyCode: code, text: nil, flags: [.maskSecondaryFn, .maskNumericPad])
        }
    }

    func switchLayout(to lang: Lang) {
        switchRequestedAt = ProcessInfo.processInfo.systemUptime
        onSwitchLayout(lang)
    }

    private func post(keyCode: UInt16, text: String?, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            if let text { event.setTypedString(text) }
            send(event)
        }
    }

    private func send(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: KeyPoster.marker)
        if inFlight == 0 { lastProgress = ProcessInfo.processInfo.systemUptime }
        inFlight += 1
        event.post(tap: .cghidEventTap)
    }
}
