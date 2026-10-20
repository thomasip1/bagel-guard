// BagelGuard: blocks the "bagel on an unlocked laptop" prank in Slack.
//
// Needs only the Accessibility permission. It watches Slack's focused message box through the
// accessibility API, swallows Return / clicks on Send while a bagel is in it, then clears the box,
// shows an overlay and (optionally) locks the screen.

import ApplicationServices
import Carbon.HIToolbox
import Cocoa
import ServiceManagement

let slackBundleID = "com.tinyspeck.slackmacgap"

// MARK: - Settings

enum Action: String, CaseIterable {
    case overlayThenLock = "lock"
    case overlay = "overlay"
    case lockOnly = "lock-only"
    case log = "log"

    var title: String {
        switch self {
        case .overlayThenLock: return "Show overlay, then lock"
        case .overlay: return "Show overlay"
        case .lockOnly: return "Lock right away"
        case .log: return "Only log it"
        }
    }
}

enum Settings {
    static let defaults = UserDefaults.standard

    static var armed: Bool {
        get { defaults.object(forKey: "armed") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "armed") }
    }

    /// `defaults write com.thomasip.bagelguard debug -bool true` logs every Return pressed in Slack.
    static var debug: Bool { defaults.bool(forKey: "debug") }

    /// Whether the overlay takes a webcam photo of whoever tried.
    static var mugshot: Bool {
        get { defaults.object(forKey: "mugshot") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "mugshot") }
    }

    /// Counts caught attempts; shown as the case number on the placard.
    static func nextCaseNumber() -> Int {
        let next = defaults.integer(forKey: "caseCount") + 1
        defaults.set(next, forKey: "caseCount")
        return next
    }

    static var action: Action {
        get { Action(rawValue: defaults.string(forKey: "action") ?? "") ?? .overlayThenLock }
        set { defaults.set(newValue.rawValue, forKey: "action") }
    }
}

// MARK: - Logging

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/BagelGuard.log")
    static let formatter = ISO8601DateFormatter()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    }
}

// MARK: - Accessibility helpers

func axAttr<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
        let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    axAttr(element, kAXChildrenAttribute) ?? []
}

// MARK: - Detection

struct Hit {
    let reason: String
    let field: String
}

enum Detector {
    /// An in-progress or finished shortcode such as `:bagel`, `:hotbagel:`, `:bagel-party-parrot:`.
    static let shortcode = try! NSRegularExpression(pattern: ":[a-z0-9_+'-]*bagel", options: [.caseInsensitive])

    /// A shortcode on its way to a bagel: `:bag`, `:hotbag`. Used to power the camera up early.
    static let partialShortcode = try! NSRegularExpression(pattern: ":[a-z0-9_+'-]*bag", options: [.caseInsensitive])

    static func isTypingBagel(focused: AXUIElement) -> Bool {
        var node: AXUIElement? = focused
        for _ in 0..<6 {
            guard let current = node else { break }
            if (axAttr(current, kAXRoleAttribute) as String?) == kAXTextAreaRole {
                let value: String = axAttr(current, kAXValueAttribute) ?? ""
                return partialShortcode.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
            }
            node = axElement(current, kAXParentAttribute)
        }
        return false
    }

    static func scan(text: String) -> String? {
        if text.contains("\u{1F96F}") { return "unicode 🥯" }
        let range = NSRange(text.startIndex..., in: text)
        if let match = shortcode.firstMatch(in: text, range: range), let r = Range(match.range, in: text) {
            return "shortcode \(text[r])"
        }
        return nil
    }

    /// Slack turns a finished emoji into an image inside the message box: an AXImage whose
    /// description is e.g. "bagel emoji" or "bagel pet emoji".
    static func scanImages(in root: AXUIElement) -> String? {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast(), visited < 400 {
            visited += 1
            let role: String? = axAttr(element, kAXRoleAttribute)
            if role == kAXImageRole {
                let label = [axAttr(element, kAXDescriptionAttribute) as String?, axAttr(element, kAXTitleAttribute)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                if label.lowercased().contains("bagel") { return "emoji image \"\(label)\"" }
            }
            if depth < 8 { stack.append(contentsOf: axChildren(element).map { ($0, depth + 1) }) }
        }
        return nil
    }

    /// Checks the focused element of Slack: the message box and its emoji images. Reactions are
    /// left alone: the emoji picker's search field is not checked.
    static func check(focused: AXUIElement) -> Hit? {
        // The focused node can be a text run inside the box; walk up to the text area.
        var node: AXUIElement? = focused
        for _ in 0..<6 {
            guard let current = node else { break }
            let role: String? = axAttr(current, kAXRoleAttribute)
            let label: String = axAttr(current, kAXDescriptionAttribute) ?? axAttr(current, kAXTitleAttribute) ?? ""
            let value: String = axAttr(current, kAXValueAttribute) ?? ""
            if role == kAXTextAreaRole {
                if let reason = scan(text: value) ?? scanImages(in: current) {
                    return Hit(reason: reason, field: label)
                }
                return nil
            }
            if role == kAXTextFieldRole || role == kAXComboBoxRole {
                if let reason = scan(text: value) { return Hit(reason: reason, field: label) }
                return nil
            }
            node = axElement(current, kAXParentAttribute)
        }
        return nil
    }
}

// MARK: - Slack watcher

final class SlackWatcher {
    private(set) var pid: pid_t?
    private var app: AXUIElement?
    private var observer: AXObserver?
    private var pollTimer: Timer?
    var onHit: ((Hit, String) -> Void)?
    var onApproach: (() -> Void)?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) {
            [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.bundleIdentifier == slackBundleID
            {
                self?.attach(app.processIdentifier)
            }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) {
            [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.processIdentifier == self?.pid
            {
                self?.detach()
            }
        }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: slackBundleID).first {
            attach(running.processIdentifier)
        }
        // AX notifications from Chromium are not guaranteed for every edit, so poll as well while
        // Slack is in front. One focused-element read plus a small subtree walk, every 250 ms.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.slackIsFrontmost else { return }
            self.check(source: "poll")
        }
    }

    /// Asks the accessibility server rather than NSWorkspace: NSWorkspace's frontmost app is
    /// updated by a notification and lags behind real focus changes.
    /// Either source counts, so a stale answer from one of them does not let a bagel through.
    var slackIsFrontmost: Bool {
        guard let pid else { return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
        guard let focusedApp = axElement(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) else {
            return false
        }
        var focusedPid: pid_t = 0
        return AXUIElementGetPid(focusedApp, &focusedPid) == .success && focusedPid == pid
    }

    private func attach(_ pid: pid_t) {
        detach()
        self.pid = pid
        let app = AXUIElementCreateApplication(pid)
        self.app = app
        // Chromium only builds its full accessibility tree when an assistive app asks for it.
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        Log.write("attached to Slack pid \(pid) (AXManualAccessibility: \(manual.rawValue))")

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<SlackWatcher>.fromOpaque(refcon).takeUnretainedValue()
            watcher.check(source: notification as String)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
            Log.write("AXObserverCreate failed; relying on polling")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedUIElementChangedNotification, kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            let err = AXObserverAddNotification(observer, app, name as CFString, refcon)
            if err != .success { Log.write("observe \(name) failed: \(err.rawValue)") }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        app = nil
        pid = nil
    }

    /// The bagel currently in Slack's focused field, if any.
    func currentHit() -> Hit? {
        guard let app, let focused = axElement(app, kAXFocusedUIElementAttribute) else { return nil }
        return Detector.check(focused: focused)
    }

    func check(source: String) {
        guard Settings.armed, let app, let focused = axElement(app, kAXFocusedUIElementAttribute) else { return }
        if let hit = Detector.check(focused: focused) {
            onHit?(hit, source)
        } else if Detector.isTypingBagel(focused: focused) {
            onApproach?()
        }
    }
}

// MARK: - Send interception (event tap)

/// Swallows Return and clicks on Slack's Send button while a bagel is in the message box. This is
/// a backstop: detection normally clears the box first. While any app holds Secure Keyboard Entry
/// the tap receives no keystrokes, so only the Send-button check works then.
final class SendInterceptor {
    private var tap: CFMachPort?
    let watcher: SlackWatcher
    var onBlocked: ((Hit, String) -> Void)?

    init(watcher: SlackWatcher) { self.watcher = watcher }


    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<SendInterceptor>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask), callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Log.write("event tap could not be created (Accessibility not granted yet?)")
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("send interceptor active")
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.write("event tap was disabled (\(type.rawValue)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard Settings.armed else { return Unmanaged.passUnretained(event) }

        if type == .keyDown {
            let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard key == kVK_Return || key == kVK_ANSI_KeypadEnter else { return Unmanaged.passUnretained(event) }
            let inSlack = watcher.slackIsFrontmost
            let hit = inSlack ? watcher.currentHit() : nil
            if Settings.debug {
                let sourcePid = event.getIntegerValueField(.eventSourceUnixProcessID)
                Log.write("debug: return (Slack focused: \(inSlack), source pid \(sourcePid)), bagel: \(hit?.reason ?? "none")")
            }
            guard let hit else { return Unmanaged.passUnretained(event) }
            onBlocked?(hit, "return key")
            return nil
        }

        if type == .leftMouseDown, let pid = watcher.pid, clickIsOnSendButton(event.location, slackPid: pid),
            let hit = watcher.currentHit()
        {
            onBlocked?(hit, "send button")
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    /// Whether the click lands on Slack's Send button. Checks the element under the pointer, so it
    /// does not depend on which app is frontmost.
    private func clickIsOnSendButton(_ point: CGPoint, slackPid: pid_t) -> Bool {
        var element: AXUIElement?
        var elementPid: pid_t = 0
        let found = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element)
        if let element { AXUIElementGetPid(element, &elementPid) }
        if Settings.debug, elementPid == slackPid || found != .success {
            let role: String? = element.flatMap { axAttr($0, kAXRoleAttribute) }
            Log.write("debug: click at \(point) -> AX \(found.rawValue), pid \(elementPid), role \(role ?? "-")")
        }
        guard found == .success, let element, elementPid == slackPid else { return false }
        var node: AXUIElement? = element
        for _ in 0..<4 {
            guard let current = node else { break }
            let role: String? = axAttr(current, kAXRoleAttribute)
            let label = (axAttr(current, kAXDescriptionAttribute) as String? ?? "") + " "
                + (axAttr(current, kAXTitleAttribute) as String? ?? "")
            if role == kAXButtonRole {
                if Settings.debug { Log.write("debug: click on Slack button \"\(label.trimmingCharacters(in: .whitespaces))\"") }
                return label.lowercased().contains("send")
            }
            node = axElement(current, kAXParentAttribute)
        }
        return false
    }
}

// MARK: - Responses

enum Responder {
    /// Select all + delete in the focused field. Only sent while Slack is in front, so the keys go
    /// to its message box.
    static func clearFocusedField() {
        let source = CGEventSource(stateID: .hidSystemState)
        func press(_ key: Int, _ flags: CGEventFlags = []) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
            }
        }
        press(kVK_ANSI_A, .maskCommand)
        press(kVK_Delete)
    }

    static func lockScreen() {
        Log.write("locking screen")
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(path, RTLD_NOW), let symbol = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockFn = @convention(c) () -> Int32
            _ = unsafeBitCast(symbol, to: LockFn.self)()
            return
        }
        // Fallback: the system Lock Screen shortcut, Ctrl+Cmd+Q.
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: down)
            event?.flags = [.maskCommand, .maskControl]
            event?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let watcher = SlackWatcher()
    lazy var interceptor = SendInterceptor(watcher: watcher)
    let overlay = OverlayController()
    var statusItem: NSStatusItem!
    var lastTrigger = Date.distantPast
    var lastReason = ""
    var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Keeps the spot the user ⌘-drags it to, so it can be moved clear of the notch once.
        statusItem.autosaveName = "BagelGuard"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        watcher.onHit = { [weak self] hit, source in self?.trigger(hit, source: source) }
        watcher.onApproach = { [weak self] in
            guard let self, Settings.mugshot, [.overlayThenLock, .overlay].contains(Settings.action) else { return }
            self.overlay.prewarmCamera()
        }
        interceptor.onBlocked = { [weak self] hit, source in
            // Called from inside the event tap; respond after the tap returns.
            DispatchQueue.main.async { self?.trigger(hit, source: source, blockedSend: true) }
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            startGuards()
        } else {
            Log.write("waiting for Accessibility permission")
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.startGuards()
            }
        }
    }

    func startGuards() {
        Log.write(
            "Accessibility granted; armed=\(Settings.armed) action=\(Settings.action.rawValue) "
                + "input-monitoring=\(CGPreflightListenEventAccess()) post-events=\(CGPreflightPostEventAccess())")
        watcher.start()
        interceptor.start()
        refreshIcon()
        if Settings.mugshot {
            MugshotCamera.requestAccessIfNeeded()
            DispatchQueue.global(qos: .utility).async { MugshotCamera.warmUp() }
        }
        if CommandLine.arguments.contains("--preview") { testOverlay() }
    }

    func trigger(_ hit: Hit, source: String, blockedSend: Bool = false) {
        let now = Date()
        let action = Settings.action
        // Log-only mode leaves the bagel in the box, so the poll would report it every 250 ms; log
        // each one once. The other modes clear the box, so any later hit is a new attempt.
        let isRepeat = action == .log && hit.reason == lastReason && now.timeIntervalSince(lastTrigger) < 30
        guard blockedSend || (!isRepeat && now.timeIntervalSince(lastTrigger) > 1 && !overlay.isShowing) else { return }
        lastTrigger = now
        lastReason = hit.reason
        Log.write(
            "BAGEL in \"\(hit.field)\": \(hit.reason) (via \(source)\(blockedSend ? ", send blocked" : "")) -> \(action.rawValue)"
        )
        guard action != .log else { return }
        if Settings.mugshot && action != .lockOnly { overlay.startCamera() }

        // The clear goes through the HID queue to the frontmost app, so give Slack a moment to take
        // it before the overlay pulls focus away. Any Return typed meanwhile queues behind the clear.
        let cleared = watcher.slackIsFrontmost
        if cleared { Responder.clearFocusedField() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (cleared ? 0.15 : 0)) { [self] in
            // Only claim a response time once the box is confirmed empty.
            let response = cleared && watcher.currentHit() == nil ? Int(Date().timeIntervalSince(now) * 1000) : nil
            func booking(_ ending: Booking.Ending) -> Booking {
                Booking(
                    destination: Booking.destination(fromField: hit.field), evidence: Booking.evidence(fromReason: hit.reason),
                    caseNumber: Settings.nextCaseNumber(), date: now, responseMilliseconds: response, ending: ending)
            }
            switch action {
            case .overlayThenLock:
                overlay.show(booking(.lock), takePhoto: Settings.mugshot)
            case .overlay:
                overlay.show(booking(.close), takePhoto: Settings.mugshot)
            case .lockOnly:
                Responder.lockScreen()
            case .log:
                break
            }
        }
    }

    // MARK: Menu

    func refreshIcon() {
        statusItem.button?.title = "🥯"
        statusItem.button?.alphaValue = Settings.armed ? 1 : 0.4
        statusItem.button?.toolTip = "BagelGuard (\(Settings.armed ? "armed" : "disarmed"))"
    }

    /// Opening the app again while it runs shows its menu at the pointer, for when the menu bar
    /// item is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !AXIsProcessTrusted() {
            menu.addItem(disabled: "Needs the Accessibility permission")
            menu.addItem(NSMenuItem(title: "Open Accessibility settings…", action: #selector(openAXSettings), keyEquivalent: ""))
        } else if !Settings.armed {
            menu.addItem(disabled: "Not watching Slack")
        } else {
            menu.addItem(disabled: watcher.pid == nil ? "Waiting for Slack to open" : "Watching Slack for bagels")
        }
        menu.addItem(.separator())

        let armed = NSMenuItem(title: "Armed", action: #selector(toggleArmed), keyEquivalent: "")
        armed.state = Settings.armed ? .on : .off
        menu.addItem(armed)
        let actions = NSMenuItem(title: "When a bagel shows up", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for action in Action.allCases {
            let item = NSMenuItem(title: action.title, action: #selector(chooseAction(_:)), keyEquivalent: "")
            item.representedObject = action.rawValue
            item.state = Settings.action == action ? .on : .off
            submenu.addItem(item)
        }
        actions.submenu = submenu
        menu.addItem(actions)
        let mugshot = NSMenuItem(title: "Take a mugshot", action: #selector(toggleMugshot), keyEquivalent: "")
        mugshot.state = Settings.mugshot ? .on : .off
        menu.addItem(mugshot)
        menu.addItem(NSMenuItem(title: "Preview overlay", action: #selector(testOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open mugshots", action: #selector(openMugshots), keyEquivalent: ""))
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Open log", action: #selector(openLog), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit BagelGuard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func toggleArmed() {
        Settings.armed.toggle()
        Log.write("armed=\(Settings.armed)")
        refreshIcon()
    }

    @objc func chooseAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = Action(rawValue: raw) else { return }
        Settings.action = action
        Log.write("action=\(action.rawValue)")
    }

    @objc func testOverlay() {
        let preview = Booking(
            destination: "#office-london", evidence: "bagel emoji", caseNumber: 42, date: Date(), responseMilliseconds: 152,
            ending: .preview)
        overlay.show(preview, takePhoto: Settings.mugshot)
    }

    @objc func toggleMugshot() {
        Settings.mugshot.toggle()
        if Settings.mugshot { MugshotCamera.requestAccessIfNeeded() }
    }

    @objc func openMugshots() {
        try? FileManager.default.createDirectory(at: MugshotArchive.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(MugshotArchive.folder)
    }

    @objc func openLog() {
        NSWorkspace.shared.open(Log.url)
    }

    @objc func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("login item change failed: \(error)")
        }
    }
}

extension NSMenu {
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}

// `BagelGuard --render out.png [photo.jpg]` draws the overlay off-screen to a PNG and exits, so the
// design can be checked without covering the screen.
if let flag = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > flag + 1 {
    let out = CommandLine.arguments[flag + 1]
    let photo = CommandLine.arguments.count > flag + 2 ? NSImage(contentsOfFile: CommandLine.arguments[flag + 2]) : nil
    let size = NSScreen.main?.frame.size ?? NSSize(width: 1728, height: 1117)
    let view = InterdictionView(
        booking: Booking(
            destination: "#office-london", evidence: "bagel emoji", caseNumber: 42, date: Date(), responseMilliseconds: 152,
            ending: .lock))
    view.paintsBackdrop = true
    view.frame = NSRect(origin: .zero, size: size)
    if let photo, let cgImage = photo.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        let face = MugshotCamera.face(in: cgImage)
        view.show(Mugshot(image: NSImage(cgImage: cgImage, size: .zero), face: face?.0, confidence: face?.1 ?? 0), quietly: true)
    } else {
        // No photo given: a synthetic sensor frame with a face box, to check the target lock.
        let frame = NSImage(size: NSSize(width: 1280, height: 720), flipped: true) { rect in
            NSGradient(starting: NSColor(white: 0.32, alpha: 1), ending: NSColor(white: 0.12, alpha: 1))?.draw(in: rect, angle: 90)
            NSColor(white: 0.45, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 520, y: 170, width: 240, height: 300)).fill()
            NSBezierPath(roundedRect: NSRect(x: 380, y: 500, width: 520, height: 400), xRadius: 200, yRadius: 200).fill()
            return true
        }
        view.show(Mugshot(image: frame, face: CGRect(x: 530, y: 200, width: 220, height: 250), confidence: 0.97), quietly: true)
    }
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    exit(0)
}

// `BagelGuard --camera-probe` logs per-frame brightness and the exposure flag for 3 s, covering the
// screen with the dark overlay tint for the second half, then exits. For tuning when the photo is taken.
if CommandLine.arguments.contains("--camera-probe") {
    CameraProbe.run()
    exit(0)
}
if CommandLine.arguments.contains("--snap-test") {
    CameraProbe.snapTest()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
