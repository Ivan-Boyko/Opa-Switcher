import CoreGraphics
import Foundation

/// Перехват клавиатуры и кликов (CGEventTap) на потоке `runLoop`.
final class EventTap {
    typealias Handler = (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    private let handler: Handler
    private let onReenable: () -> Void
    private let runLoop: CFRunLoop
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    /// - Parameter onReenable: перехват был выключен системой — нажатия за это время мы не видели.
    init(runLoop: CFRunLoop, handler: @escaping Handler, onReenable: @escaping () -> Void) {
        self.runLoop = runLoop
        self.handler = handler
        self.onReenable = onReenable
    }

    var isRunning: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        guard port == nil else { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: eventTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        port = nil
        source = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Система отключает перехват, если обработчик тормозил, — включаем обратно.
            log.error("Перехват отключён системой (\(type == .tapDisabledByTimeout ? "таймаут" : "ввод")), включаю")
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            onReenable()
            return Unmanaged.passUnretained(event)
        }
        return handler(type, event)
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}

extension CGEvent {
    /// Символы, которые система приписала нажатию (с учётом текущей раскладки).
    var typedString: String {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: length)
    }

    func setTypedString(_ text: String) {
        let utf16 = Array(text.utf16)
        keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    }
}
