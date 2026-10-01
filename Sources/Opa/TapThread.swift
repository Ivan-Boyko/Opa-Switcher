import Foundation

/// Отдельный поток с run loop для перехвата клавиатуры.
/// Главный поток может подвиснуть (смена раскладки ждёт активное приложение, Accessibility, меню),
/// а пока перехватчик не ответил, система не отдаёт нажатия никому.
final class TapThread: Thread {
    private(set) var runLoop: CFRunLoop!
    private let ready = DispatchSemaphore(value: 0)

    func startAndWait() {
        name = "Opa.tap"
        qualityOfService = .userInteractive
        start()
        ready.wait()
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // Пустой источник, чтобы run loop не завершился, пока перехват ещё не создан.
        var context = CFRunLoopSourceContext()
        let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
        CFRunLoopAddSource(runLoop, keepAlive, .commonModes)
        ready.signal()
        CFRunLoopRun()
    }

    /// Выполнить на потоке перехвата (там живёт всё состояние набора).
    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}
