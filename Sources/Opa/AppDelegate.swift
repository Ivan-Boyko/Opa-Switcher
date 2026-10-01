import AppKit
import Carbon
import ServiceManagement
import SwitcherCore

/// Всё, что читает обработчик нажатий. Живёт на потоке перехвата; главный поток меняет его через `onTap`.
private struct TapState {
    var doubleShift = true
    var hotkey: Hotkey?
    /// Окно записи сочетания ждёт нажатий — ничего не перехватываем.
    var recordingHotkey = false
    var excludedApps: Set<String> = []
    var ignoredWords: Set<String> = []
    var frontmostBundleID: String?
    var frontmostPID: pid_t?
    var currentLang: Lang?
    var hasLayouts = false
    /// Когда и где последний раз набирали буквы: курсор, скорее всего, ещё в текстовом поле.
    var lastTypedAt: TimeInterval = 0
    var lastTypedPID: pid_t?
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // Главный поток.
    private let settings = Settings()
    private let detector = Detector()
    private let tapThread = TapThread()
    private var statusItem: NSStatusItem!
    private var layouts: LayoutPair?
    private var currentLang: Lang?
    private var excludedApps: Set<String> = []
    private var tap: EventTap?
    private var permissionTimer: Timer?
    private var healthTimer: Timer?
    private var requestedInputMonitoring = false
    private var hotkeyWindow: HotkeyWindow?
    private var tapRetryScheduled = false

    // Поток перехвата — трогать только там.
    private var state = TapState()
    private var engine: LineEngine?
    private var poster: KeyPoster?
    private let spellCheck = SpellCheck()
    private let doubleShift = DoubleShiftDetector()
    /// Клавиши, чьё нажатие проглочено, — их отпускание тоже глотаем.
    private var swallowedKeyUps = Set<UInt16>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        loadDictionaries()
        excludedApps = settings.excludedApps
        state.doubleShift = settings.doubleShift
        state.hotkey = settings.hotkey
        state.excludedApps = excludedApps
        state.ignoredWords = settings.ignoredWords
        state.frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        state.frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        tapThread.startAndWait()
        setupLayouts()
        observeSystem()
        startWhenTrusted()
        updateStatusTitle()
        // Доступ могут отозвать на ходу — тогда ждём его заново.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.checkPermission()
        }
    }

    private func onTap(_ block: @escaping () -> Void) {
        tapThread.perform(block)
    }

    // MARK: - Настройка

    private func loadDictionaries() {
        for lang in Lang.allCases {
            guard let url = resourceURL(lang.rawValue, "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                log.error("Нет словаря \(lang.rawValue).txt")
                continue
            }
            detector.load(lang, wordList: text)
        }
        detector.spellCheck = { [spellCheck] word, lang in spellCheck.isCorrect(word, lang) }
        detector.spellCorrection = { [spellCheck] word, lang in spellCheck.correction(word, lang) }
    }

    private func resourceURL(_ name: String, _ ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        // Запуск без .app (swift run из корня проекта).
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/\(name).\(ext)")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    private func setupLayouts() {
        let pair = LayoutPair.discover()
        layouts = pair
        currentLang = pair?.currentLang
        let lang = currentLang
        let autoSwitch = settings.autoSwitch
        let typoFix = settings.typoFix
        onTap { [self] in
            state.hasLayouts = pair != nil
            state.currentLang = lang
            guard let pair else {
                engine?.reset()
                return
            }
            if let engine, let poster {
                engine.layouts = pair
                poster.layouts = pair
                engine.reset()
                return
            }
            let poster = KeyPoster(layouts: pair)
            let engine = LineEngine(layouts: pair, detector: detector)
            engine.output = poster
            engine.autoSwitchEnabled = autoSwitch
            engine.typoFixEnabled = typoFix
            engine.autoSwitchAllowed = { [unowned self] in
                state.hasLayouts && !state.excludedApps.contains(state.frontmostBundleID ?? "")
            }
            engine.currentLang = { [unowned self] in state.currentLang }
            engine.isIgnored = { [unowned self] word in state.ignoredWords.contains(word) }
            engine.onAutoConversionUndone = { [unowned self] word in
                state.ignoredWords.insert(word)
                let words = state.ignoredWords
                DispatchQueue.main.async { self.settings.ignoredWords = words }
            }
            poster.onSwitchLayout = { [unowned self] lang in
                // Следующие нажатия движок читает уже в новой раскладке, не дожидаясь системы.
                state.currentLang = lang
                DispatchQueue.main.async { self.selectLayout(lang) }
            }
            self.poster = poster
            self.engine = engine
        }
    }

    private func observeSystem() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(inputSourceChanged),
                           name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                           object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(enabledInputSourcesChanged),
                           name: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                           object: nil, suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil)
    }

    @objc private func inputSourceChanged() {
        let lang = layouts?.currentLang
        reportLayout(lang)
        // Уведомление бывает раньше, чем система отдаёт новую раскладку, — сверяемся ещё раз.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in reportLayout(layouts?.currentLang) }
    }

    /// Главный поток. Смена раскладки по просьбе движка: вызов в другой процесс, клавиатура его не ждёт.
    private func selectLayout(_ lang: Lang) {
        guard let layouts else { return reportLayout(nil) }
        let status = layouts.select(lang)
        if layouts.currentLang == lang { reportLayout(lang) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            let now = layouts.currentLang
            if now != lang {
                log.notice("раскладка: просил \(lang.rawValue, privacy: .public), стала \(now?.rawValue ?? "?", privacy: .public), код \(status)")
            }
            reportLayout(now)
        }
    }

    /// Главный поток. Какая раскладка включена на самом деле — для строки меню и для движка.
    private func reportLayout(_ lang: Lang?) {
        currentLang = lang
        onTap { [self] in
            state.currentLang = lang
            poster?.layoutSwitched()
        }
        updateStatusTitle()
    }

    @objc private func enabledInputSourcesChanged() {
        setupLayouts()
        updateStatusTitle()
    }

    @objc private func appActivated(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let id = app?.bundleIdentifier
        let pid = app?.processIdentifier
        onTap { [self] in
            state.frontmostBundleID = id
            state.frontmostPID = pid
            resetTyping()
        }
    }

    // MARK: - Разрешения

    private func startWhenTrusted() {
        if AXIsProcessTrusted() {
            startTap()
            return
        }
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        waitForPermission()
    }

    private func waitForPermission() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted() else { return }
            timer.invalidate()
            self.startTap()
        }
    }

    private func startTap() {
        if tap == nil {
            tap = EventTap(runLoop: tapThread.runLoop, handler: { [unowned self] type, event in
                handle(type, event)
            }, onReenable: { [unowned self] in
                resetTyping()
            })
        }
        let wasRunning = tap?.isRunning == true
        let started = tap?.start() == true
        if started, !wasRunning { log.notice("Перехват запущен") }
        if !started, !tapRetryScheduled {
            // Система может требовать ещё и «Мониторинг ввода».
            if !requestedInputMonitoring {
                requestedInputMonitoring = true
                log.error("Перехват не создаётся, прошу «Мониторинг ввода»")
                CGRequestListenEventAccess()
            }
            tapRetryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.tapRetryScheduled = false
                self?.startTap()
            }
        }
        updateStatusTitle()
    }

    private func checkPermission() {
        if !AXIsProcessTrusted(), let tap, tap.isRunning {
            tap.stop()
            onTap { [self] in resetTyping() }
            waitForPermission()
        }
        updateStatusTitle()
    }

    // MARK: - Поток перехвата

    private func resetTyping() {
        engine?.reset()
        poster?.reset()
        doubleShift.interrupt()
        swallowedKeyUps.removeAll()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        // Свои синтетические нажатия не трогаем.
        if event.getIntegerValueField(.eventSourceUserData) == KeyPoster.marker {
            if type == .keyDown || type == .keyUp { poster?.ownEventArrived() }
            return pass
        }

        switch type {
        case .keyDown:
            doubleShift.interrupt()
            spellCheck.warmUpIfIdle()
            guard let engine, let poster else { return pass }
            var text: String?
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // Своё сочетание — раньше движка: сочетания с ⌘/⌃/⌥ сбрасывают строку, а её и надо перевести.
            if let hotkey = state.hotkey, !state.recordingHotkey, hotkey.matches(keyCode: keyCode, flags: event.flags) {
                swallowedKeyUps.insert(keyCode)
                if !autorepeat { requestConversion() }
                return nil
            }
            if autorepeat, keyCode != KeyCode.delete {
                // Клавишу держат: автоповтор или меню акцентов — что попало в поле, неизвестно.
                engine.reset()
            } else if keyCode == 9, event.flags.contains(.maskCommand), !event.flags.contains(.maskControl) {
                // ⌘V: запоминаем вставленный текст — двойной Shift сможет его перевести.
                engine.paste(NSPasteboard.general.string(forType: .string) ?? "")
            } else {
                let f = event.flags
                let flags = KeyFlags(shift: f.contains(.maskShift), caps: f.contains(.maskAlphaShift),
                                     command: f.contains(.maskCommand), control: f.contains(.maskControl),
                                     option: f.contains(.maskAlternate), function: f.contains(.maskSecondaryFn))
                if engine.keyDown(keyCode: keyCode, flags: flags, chars: event.typedString) == .swallow {
                    swallowedKeyUps.insert(keyCode)
                    return nil
                }
                text = engine.lastKeyText
                if text != nil {
                    state.lastTypedAt = ProcessInfo.processInfo.systemUptime
                    state.lastTypedPID = state.frontmostPID
                }
            }
            return forward(event, poster, text: text)

        case .keyUp:
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            if swallowedKeyUps.remove(keyCode) != nil { return nil }
            guard let poster else { return pass }
            return forward(event, poster, text: nil)

        case .flagsChanged:
            modifierChanged(event)
            return pass

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Курсор мог переехать — набранная строка больше не перед ним.
            doubleShift.interrupt()
            engine?.reset()
            return pass

        default:
            return pass
        }
    }

    /// Пока наши исправления в пути или раскладка меняется, реальное нажатие отправляем следом
    /// за ними, а не вперёд, — с тем символом, который учёл движок.
    private func forward(_ event: CGEvent, _ poster: KeyPoster, text: String?) -> Unmanaged<CGEvent>? {
        guard poster.isBusy() else { return Unmanaged.passUnretained(event) }
        poster.replay(event, text: text)
        return nil
    }

    private func modifierChanged(_ event: CGEvent) {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        guard keyCode == KeyCode.leftShift || keyCode == KeyCode.rightShift, !state.recordingHotkey,
              flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty else {
            doubleShift.interrupt()
            return
        }
        // Биты конкретной клавиши: левый Shift — 0x2, правый — 0x4.
        let deviceBits = flags.rawValue & 0x6
        let bit: UInt64 = keyCode == KeyCode.leftShift ? 0x2 : 0x4
        let down = deviceBits != 0 ? flags.rawValue & bit != 0 : flags.contains(.maskShift)
        if doubleShift.shift(down: down, at: ProcessInfo.processInfo.systemUptime), state.doubleShift {
            requestConversion()
        }
    }

    /// Двойной Shift или своё сочетание: перевести слово перед курсором или выделение.
    private func requestConversion() {
        // Поле пароля и т.п.: нажатия до нас не доходят, строка неизвестна.
        guard let engine, state.hasLayouts, !IsSecureEventInputEnabled() else { return }
        let revision = engine.revision
        let pid = state.frontmostPID
        // Accessibility может отвечать долго — читаем поле в фоне, клавиатура не ждёт.
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            let snapshot = Selection.snapshot(pid: pid)
            onTap { [self] in finishDoubleShift(revision: revision, snapshot: snapshot) }
        }
    }

    private func finishDoubleShift(revision: Int, snapshot: Selection.Snapshot) {
        // Пока читали поле, пользователь продолжил печатать — отменяем.
        guard let engine, engine.revision == revision else { return }
        if snapshot.selectionLength > 0 {
            // Выделение сразу за набранным — подсказка автодополнения (Spotlight): переводим набранное.
            // Своё выделение пользователь делает мышью или Shift+стрелками — тогда буфер уже сброшен.
            if engine.doubleShift(beforeCaret: snapshot.textBeforeCaret) { return }
            // 1. Выделенный текст.
            if let text = snapshot.selectedText, engine.convertText(text, deleting: 0) { return }
        } else {
            // 2. Откат последней замены или слово у курсора — если буфер совпадает с полем.
            if engine.doubleShift(beforeCaret: snapshot.textBeforeCaret) { return }
            // 3. Слово перед курсором из самого поля (после клика, автозамены).
            if let before = snapshot.textBeforeCaret, let word = Selection.lastWord(in: before),
               engine.convertText(word.text, deleting: word.count) { return }
        }
        // 4. Поле не отдаёт текст (VS Code, Chrome), а буфер сброшен кликом — берём текст через буфер обмена.
        if snapshot.textBeforeCaret == nil, clipboardAllowed() {
            let revision = engine.revision
            DispatchQueue.global(qos: .userInteractive).async { [self] in
                let result = ClipboardText.read { shortcut in onTap { [self] in poster?.post(shortcut) } }
                onTap { [self] in finishClipboardDoubleShift(revision: revision, result: result) }
            }
            return
        }
        toggleLayout()
    }

    /// Буфер обмена трогаем, только если курсор, скорее всего, в текстовом поле: недавно печатали
    /// в этом же приложении. И не в терминале: там ⌘⇧← и ⌘C значат другое.
    private func clipboardAllowed() -> Bool {
        guard let id = state.frontmostBundleID, !ClipboardText.terminals.contains(id),
              state.lastTypedPID == state.frontmostPID else { return false }
        return ProcessInfo.processInfo.systemUptime - state.lastTypedAt < 120
    }

    private func finishClipboardDoubleShift(revision: Int, result: ClipboardText.Result) {
        // Пока читали буфер обмена, пользователь продолжил печатать — отменяем.
        guard let engine, engine.revision == revision else { return }
        switch result {
        case let .selection(text):
            if engine.convertText(text, deleting: 0) { return }
        case let .beforeCaret(text):
            if let word = Selection.lastWord(in: text), engine.convertText(word.text, deleting: word.count) { return }
        case .nothing:
            break
        }
        toggleLayout()
    }

    /// Переводить нечего — просто переключаем раскладку.
    private func toggleLayout() {
        if let lang = state.currentLang { poster?.switchLayout(to: lang.other) }
    }

    // MARK: - Меню

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        let working = AXIsProcessTrusted() && tap?.isRunning == true && layouts != nil
        let title = working ? (currentLang?.rawValue.uppercased() ?? "⌨︎") : "⚠︎"
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: settings.autoSwitch ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        button.toolTip = working ? "Опа" : "Опа: нет доступа или раскладок"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !AXIsProcessTrusted() || tap?.isRunning != true {
            menu.addItem(item("⚠︎ Дать доступ в «Универсальный доступ»…", #selector(openAccessibilitySettings)))
            menu.addItem(.separator())
        }
        if layouts == nil {
            menu.addItem(disabled("Включите раскладки ABC (или US) и Русскую"))
            menu.addItem(.separator())
        }

        menu.addItem(item("Автопереключение раскладки", #selector(toggleAutoSwitch), on: settings.autoSwitch))
        let typos = item("Исправлять опечатки", #selector(toggleTypoFix), on: settings.typoFix)
        typos.toolTip = "Пропущенная, лишняя или соседняя буква, две буквы местами: «спасбо» → «спасибо». "
            + "Двойной Shift сразу после — вернуть как было и больше не исправлять это слово."
        menu.addItem(typos)
        menu.addItem(item("Двойной Shift — исправить слово или выделение", #selector(toggleDoubleShift),
                          on: settings.doubleShift))
        let hotkeyTitle = settings.hotkey.map { "Сочетание клавиш: \($0.title(layout: layouts?.latin))…" }
        menu.addItem(item(hotkeyTitle ?? "Задать сочетание клавиш…", #selector(showHotkeyWindow)))
        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
           id != Bundle.main.bundleIdentifier {
            let exclude = item("Не исправлять автоматически в «\(app.localizedName ?? id)»",
                               #selector(toggleExcludedApp(_:)), on: excludedApps.contains(id))
            exclude.representedObject = id
            menu.addItem(exclude)
        }

        menu.addItem(.separator())
        if let layouts {
            menu.addItem(disabled("\(layouts.latin.name) ⇄ \(layouts.cyrillic.name)"))
        }
        let ignored = settings.ignoredWords
        if !ignored.isEmpty {
            let forget = item("Забыть слова-исключения (\(ignored.count))", #selector(clearIgnoredWords))
            forget.toolTip = ignored.sorted().prefix(20).joined(separator: ", ")
            menu.addItem(forget)
        }
        let login = item("Запускать при входе", #selector(toggleLaunchAtLogin))
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed // ждёт подтверждения в Системных настройках
        default: login.state = .off
        }
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("О программе", #selector(showAbout)))
        if projectURL != nil { menu.addItem(item("Сообщить о проблеме…", #selector(reportProblem))) }
        menu.addItem(item("Выйти", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, on: Bool? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let on { item.state = on ? .on : .off }
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleAutoSwitch() {
        settings.autoSwitch.toggle()
        let on = settings.autoSwitch
        onTap { [self] in engine?.autoSwitchEnabled = on }
        updateStatusTitle()
    }

    @objc private func toggleTypoFix() {
        settings.typoFix.toggle()
        let on = settings.typoFix
        onTap { [self] in engine?.typoFixEnabled = on }
    }

    @objc private func showHotkeyWindow() {
        if let hotkeyWindow { return hotkeyWindow.show() }
        let window = HotkeyWindow(hotkey: settings.hotkey, layout: layouts?.latin)
        window.onChange = { [self] hotkey in
            settings.hotkey = hotkey
            onTap { [self] in state.hotkey = hotkey }
        }
        window.onRecording = { [self] recording in onTap { [self] in state.recordingHotkey = recording } }
        window.onClose = { [self] in hotkeyWindow = nil }
        hotkeyWindow = window
        window.show()
    }

    @objc private func toggleDoubleShift() {
        settings.doubleShift.toggle()
        let on = settings.doubleShift
        onTap { [self] in state.doubleShift = on }
    }

    @objc private func toggleExcludedApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if excludedApps.contains(id) { excludedApps.remove(id) } else { excludedApps.insert(id) }
        settings.excludedApps = excludedApps
        let apps = excludedApps
        onTap { [self] in state.excludedApps = apps }
    }

    @objc private func clearIgnoredWords() {
        settings.ignoredWords = []
        onTap { [self] in state.ignoredWords = [] }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }

    @objc private func openAccessibilitySettings() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        waitForPermission()
    }

    /// Страница проекта (Info.plist, OpaProjectURL).
    private var projectURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "OpaProjectURL") as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    @objc private func showAbout() {
        var text = "Исправляет текст, набранный не в той раскладке, и опечатки. Бесплатно, открытый код (MIT).\n\n"
            + "Частотные словари — FrequencyWords © Hermit Dave (по субтитрам OpenSubtitles), CC BY-SA 4.0."
        if let projectURL { text += "\n\n\(projectURL.absoluteString)" }
        let credits = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
        ])
        if let projectURL {
            credits.addAttribute(.link, value: projectURL, range: (text as NSString).range(of: projectURL.absoluteString))
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func reportProblem() {
        guard let projectURL else { return }
        NSWorkspace.shared.open(projectURL.appendingPathComponent("issues"))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
