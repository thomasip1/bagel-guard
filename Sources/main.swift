// BagelGuard: blocks the "bagel on an unlocked laptop" prank in Slack.
//
// Watches Slack's focused message box through the accessibility API. When a bagel shows up (the
// emoji, its shortcode or the word), it clears the box, covers every screen with an overlay showing
// a webcam photo of whoever is at the keyboard, saves it, and locks the screen when clicked.
// Needs the Accessibility permission, plus Camera for the photo.

import ApplicationServices
import Carbon.HIToolbox
import Cocoa
import LocalAuthentication
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

    var showsOverlay: Bool { self == .overlayThenLock || self == .overlay }
}

enum Settings {
    static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: ["armed": true, "mugshot": true, "action": Action.overlayThenLock.rawValue])
    }

    static var armed: Bool {
        get { defaults.bool(forKey: "armed") }
        set { defaults.set(newValue, forKey: "armed") }
    }

    /// Whether the overlay takes a webcam photo of whoever tried.
    static var mugshot: Bool {
        get { defaults.bool(forKey: "mugshot") }
        set { defaults.set(newValue, forKey: "mugshot") }
    }

    static var action: Action {
        get { Action(rawValue: defaults.string(forKey: "action") ?? "") ?? .overlayThenLock }
        set { defaults.set(newValue.rawValue, forKey: "action") }
    }

    /// Counts caught attempts; shown as the case number on the overlay.
    static func nextCaseNumber() -> Int {
        let next = defaults.integer(forKey: "caseCount") + 1
        defaults.set(next, forKey: "caseCount")
        return next
    }

    /// Turning any safeguard off is a pause: it turns itself back on after this long.
    static let reengageAfter: TimeInterval = 3 * 60

    /// When a turned-off safeguard comes back on. Persisted so a relaunch doesn't extend the pause.
    static func reengageAt(_ safeguard: Safeguard) -> Date? {
        defaults.object(forKey: "reengageAt.\(safeguard.rawValue)") as? Date
    }

    static func setReengageAt(_ safeguard: Safeguard, _ date: Date?) {
        defaults.set(date, forKey: "reengageAt.\(safeguard.rawValue)")
    }
}

/// A setting in the menu that weakens BagelGuard when turned off.
enum Safeguard: String, CaseIterable {
    case armed, action, mugshot, loginItem

    var isEngaged: Bool {
        switch self {
        case .armed: return Settings.armed
        case .action: return Settings.action == .overlayThenLock
        case .mugshot: return Settings.mugshot
        case .loginItem: return SMAppService.mainApp.status == .enabled
        }
    }

    func engage() {
        switch self {
        case .armed: Settings.armed = true
        case .action: Settings.action = .overlayThenLock
        case .mugshot:
            Settings.mugshot = true
            MugshotCamera.requestAccessIfNeeded()
        case .loginItem:
            do { try SMAppService.mainApp.register() } catch { Log.write("login item change failed: \(error)") }
        }
    }
}

// MARK: - Logging

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BagelGuard.log")
    private static let formatter = ISO8601DateFormatter()
    private static let queue = DispatchQueue(label: "com.thomasip.bagelguard.log")
    private static let file: FileHandle? = {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        return handle
    }()

    static func write(_ message: String) {
        let line = Data("\(formatter.string(from: Date())) \(message)\n".utf8)
        queue.async {
            FileHandle.standardError.write(line)
            file?.write(line)
        }
    }
}

// MARK: - Owner check

/// Asks for Touch ID before any settings change, so whoever is at the unlocked Mac can't disarm
/// BagelGuard first. Falls back to the login password only when Touch ID isn't available (lid shut,
/// no Touch ID keyboard), so the owner is never locked out of their own settings.
enum OwnerCheck {
    static func require(_ reason: String, then action: @escaping () -> Void) {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        NSApp.activate(ignoringOtherApps: true)
        context.evaluatePolicy(policy, localizedReason: reason) { ok, error in
            DispatchQueue.main.async {
                if ok {
                    action()
                } else {
                    Log.write("owner check refused (\(reason)): \(error?.localizedDescription ?? "unknown")")
                }
            }
        }
    }
}

// MARK: - Accessibility helpers

/// Caps accessibility calls, so a hung app can't stall the event tap. Clicks hit-test whatever app
/// is under the pointer, so that cap is tight; Slack's own calls get more room.
let systemWide: AXUIElement = {
    let element = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(element, 0.25)
    return element
}()
let slackTimeout: Float = 1

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

/// The element and up to `limit - 1` of its ancestors, nearest first.
func axAncestors(_ element: AXUIElement, limit: Int) -> some Sequence<AXUIElement> {
    sequence(first: element) { axElement($0, kAXParentAttribute) }.prefix(limit)
}

/// Where the element is on screen, in global top-left-origin points.
func axFrame(_ element: AXUIElement) -> CGRect? {
    var position: CFTypeRef?, size: CFTypeRef?
    var origin = CGPoint.zero, extent = CGSize.zero
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
        let position, let size,
        CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
        AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent)
    else { return nil }
    return CGRect(origin: origin, size: extent)
}

/// What the element says about itself: its description, or else its title.
func axLabel(_ element: AXUIElement) -> String {
    let description: String = axAttr(element, kAXDescriptionAttribute) ?? ""
    return description.isEmpty ? axAttr(element, kAXTitleAttribute) ?? "" : description
}

// MARK: - Detection

/// What was found in the message box.
enum Evidence: Equatable, CustomStringConvertible {
    /// The 🥯 character, typed or pasted, before Slack turns it into an image.
    case character
    /// A shortcode, finished or not: `:bagel`, `:hotbagel:`.
    case shortcode(String)
    /// The word itself: "bagel", "Bagels".
    case word(String)
    /// A converted emoji: Slack's image label, e.g. "bagel pet emoji".
    case emoji(String)
    /// Jev's judgment of the box as rendered and its text, e.g. "looks like a bagel (Jev 93%)".
    case jev(String)

    var description: String {
        switch self {
        case .character: return "unicode 🥯"
        case .shortcode(let text): return "shortcode \(text)"
        case .word(let text): return "text \"\(text)\""
        case .emoji(let label): return "emoji image \"\(label)\""
        case .jev(let reason): return "jev: \(reason)"
        }
    }

    /// How the overlay names it.
    var displayName: String {
        switch self {
        case .character: return "🥯 U+1F96F"
        case .shortcode(let text): return "\(text) shortcode"
        case .word(let text): return "the word \"\(text)\""
        case .emoji(let label): return label
        case .jev(let reason): return reason
        }
    }
}

struct Hit: Equatable {
    let evidence: Evidence
    /// The message box's label, e.g. "Message to office-london".
    let field: String
}

enum Observation {
    case bagel(Hit)
    /// A bagel shortcode or word is being typed; used to power the camera up early.
    case approaching
    case clean
}

enum Detector {
    static let shortcode = try! NSRegularExpression(pattern: ":[a-z0-9_+'-]*bagel", options: [.caseInsensitive])
    static let word = try! NSRegularExpression(pattern: "bagel", options: [.caseInsensitive])
    /// `:bag`, `:hotbag`, or a word starting "bage" (plain "bag" is too common, and "garbage" isn't one).
    static let partial = try! NSRegularExpression(pattern: ":[a-z0-9_+'-]*bag|\\bbage", options: [.caseInsensitive])

    /// Looks at Slack's focused field. Message boxes (text areas) count the emoji, its shortcode, the
    /// word and converted emoji images. Other fields, such as search, count only the emoji and
    /// shortcodes, so searching Slack for "bagel" doesn't lock the Mac. Reactions are left alone.
    static func observe(focused: AXUIElement) -> Observation {
        // The focused node can be a text run inside the box; walk up to the field.
        for node in axAncestors(focused, limit: 6) {
            let role: String? = axAttr(node, kAXRoleAttribute)
            guard role == kAXTextAreaRole || role == kAXTextFieldRole || role == kAXComboBoxRole else { continue }
            let value: String = axAttr(node, kAXValueAttribute) ?? ""
            let isMessageBox = role == kAXTextAreaRole
            if let evidence = scan(value, plainText: isMessageBox) ?? (isMessageBox ? scanImages(in: node) : nil) {
                return .bagel(Hit(evidence: evidence, field: axLabel(node)))
            }
            return isMessageBox && first(partial, in: value) != nil ? .approaching : .clean
        }
        return .clean
    }

    static func scan(_ text: String, plainText: Bool) -> Evidence? {
        if text.contains("\u{1F96F}") { return .character }
        if let match = first(shortcode, in: text) { return .shortcode(match) }
        if plainText, let match = first(word, in: text) { return .word(match) }
        return nil
    }

    /// Slack turns a finished emoji into an AXImage inside the message box, labelled e.g. "bagel
    /// emoji" or "bagel pet emoji".
    static func scanImages(in root: AXUIElement) -> Evidence? {
        imageLabels(in: root).first { $0.lowercased().contains("bagel") }.map(Evidence.emoji)
    }

    static func imageLabels(in root: AXUIElement) -> [String] {
        var labels: [String] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast(), visited < 400 {
            visited += 1
            if (axAttr(element, kAXRoleAttribute) as String?) == kAXImageRole {
                labels.append(axLabel(element))
            }
            if depth < 8 { stack.append(contentsOf: axChildren(element).map { ($0, depth + 1) }) }
        }
        return labels
    }

    /// The message box (a text area) the focused node sits in, if any.
    static func messageBox(focused: AXUIElement) -> AXUIElement? {
        axAncestors(focused, limit: 6).first { (axAttr($0, kAXRoleAttribute) as String?) == kAXTextAreaRole }
    }

    private static func first(_ regex: NSRegularExpression, in text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range, in: text)
        else { return nil }
        return String(text[range])
    }
}

// MARK: - Slack watcher

final class SlackWatcher {
    private(set) var pid: pid_t?
    private var app: AXUIElement?
    private var observer: AXObserver?
    private var pollTimer: Timer?
    private var checkScheduled = false
    /// The last report, so each attempt (or approach) is reported once rather than on every check.
    private var reported: Hit?
    private var reportedApproach = false
    /// When a bagel (or approaching text) was last seen in the focused field. The send interceptor
    /// uses this to block Enter during the AX tree gap when Slack's autocomplete replaces a shortcode
    /// with an emoji image — currentHit() briefly returns nil even though a bagel just arrived.
    private(set) var lastSightingDate: Date?
    var onHit: ((Hit, String) -> Void)?
    var onApproach: (() -> Void)?
    /// The message box content once typing pauses, for Jev to screen.
    var onContentSettled: ((MessageSnapshot) -> Void)?
    private var lastContentKey: String?
    private var settleTimer: Timer?

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
        // Chromium doesn't post an AX notification for every edit, so also poll while Slack is in front.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let pid = self.pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.check(source: "poll")
        }
        timer.tolerance = 0.05
        pollTimer = timer
    }

    /// Either NSWorkspace or the accessibility server counts: NSWorkspace's frontmost app updates
    /// on a notification and can lag behind a focus change.
    var slackIsFrontmost: Bool {
        guard let pid else { return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
        guard let focusedApp = axElement(systemWide, kAXFocusedApplicationAttribute) else { return false }
        var focusedPid: pid_t = 0
        return AXUIElementGetPid(focusedApp, &focusedPid) == .success && focusedPid == pid
    }

    private func attach(_ pid: pid_t) {
        detach()
        self.pid = pid
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, slackTimeout)
        self.app = app
        // Chromium only builds its full accessibility tree when an assistive app asks for it.
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        Log.write("attached to Slack pid \(pid) (AXManualAccessibility: \(manual.rawValue))")

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            Unmanaged<SlackWatcher>.fromOpaque(refcon).takeUnretainedValue().scheduleCheck(source: notification as String)
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

    /// One keystroke posts several notifications; check once for all of them.
    private func scheduleCheck(source: String) {
        guard !checkScheduled else { return }
        checkScheduled = true
        DispatchQueue.main.async { [self] in
            checkScheduled = false
            check(source: source)
        }
    }

    private func observeFocused() -> Observation {
        guard let app, let focused = axElement(app, kAXFocusedUIElementAttribute) else { return .clean }
        return Detector.observe(focused: focused)
    }

    /// What Slack's focused message box holds, if a message box has focus.
    func messageSnapshot() -> MessageSnapshot? {
        guard let app, let focused = axElement(app, kAXFocusedUIElementAttribute),
            let box = Detector.messageBox(focused: focused)
        else { return nil }
        return MessageSnapshot(
            text: axAttr(box, kAXValueAttribute) ?? "", emojiLabels: Detector.imageLabels(in: box),
            field: axLabel(box), frame: axFrame(box))
    }

    /// The bagel currently in Slack's focused field, if any.
    func currentHit() -> Hit? {
        if case .bagel(let hit) = observeFocused() { return hit }
        return nil
    }

    func check(source: String) {
        guard Settings.armed else { return }
        let observation = observeFocused()
        if case .approaching = observation {
            lastSightingDate = Date()
            if !reportedApproach { onApproach?() }
            reportedApproach = true
        } else {
            reportedApproach = false
        }
        if case .bagel(let hit) = observation {
            lastSightingDate = Date()
            guard hit != reported else { return }
            reported = hit
            onHit?(hit, source)
        } else {
            if reported != nil, let last = lastSightingDate, Date().timeIntervalSince(last) > 2 {
                reported = nil
            }
            noteContent()
        }
    }

    /// Hands the message box to Jev once its content has been still for a moment.
    private func noteContent() {
        guard onContentSettled != nil, let snapshot = messageSnapshot(), !snapshot.isEmpty else {
            lastContentKey = nil
            settleTimer?.invalidate()
            return
        }
        guard snapshot.key != lastContentKey else { return }
        lastContentKey = snapshot.key
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self, let now = self.messageSnapshot(), now.key == snapshot.key else { return }
            self.onContentSettled?(now)
        }
    }

    /// Report a bagel still in the box again, e.g. after the overlay closes without it being cleared.
    func forgetReported() {
        reported = nil
    }
}

// MARK: - Send interception (event tap)

/// Swallows Return and clicks on Slack's Send button while a bagel is in the message box. This is
/// a backstop: detection normally clears the box first. While any app holds Secure Keyboard Entry
/// the tap receives no keystrokes, so only the Send-button check works then.
final class SendInterceptor {
    private var tap: CFMachPort?
    let watcher: SlackWatcher
    let jev: JevGuard
    var onBlocked: ((Hit, String) -> Void)?
    /// A send held while Jev looks at the message.
    private var holding = false
    /// Marks the Return or click replayed after Jev clears a held send, so the tap lets it through.
    private static let replayMarker: Int64 = 0x6261_6765_6C

    init(watcher: SlackWatcher, jev: JevGuard) {
        self.watcher = watcher
        self.jev = jev
    }

    func start() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            Unmanaged<SendInterceptor>.fromOpaque(refcon!).takeUnretainedValue().handle(type: type, event: event)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask), callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return Log.write("event tap could not be created") }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("send interceptor active")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.write("event tap was disabled (\(type.rawValue)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.replayMarker else { return pass }
        guard Settings.armed, Settings.action != .log, let slackPid = watcher.pid else { return pass }

        if type == .keyDown {
            let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard key == kVK_Return || key == kVK_ANSI_KeypadEnter, watcher.slackIsFrontmost
            else { return pass }
            // Re-scan now; if clean, check whether a bagel was sighted very recently (covers the
            // AX-tree gap when Slack's autocomplete swaps a shortcode for an emoji image).
            if let hit = watcher.currentHit() {
                onBlocked?(hit, "return key")
                return nil
            }
            if let last = watcher.lastSightingDate, Date().timeIntervalSince(last) < 1.5 {
                let stale = Hit(evidence: .shortcode(":bagel-like:"), field: "(recent)")
                onBlocked?(stale, "return key (recent sighting)")
                return nil
            }
            // Shift-Return is a new line, not a send.
            if !event.flags.contains(.maskShift), jevHolds(source: "return key", replay: Self.replayReturn) {
                return nil
            }
            return pass
        }

        if type == .leftMouseDown, windowOwner(under: event) ?? slackPid == slackPid,
            clickIsOnSendButton(event.location, slackPid: slackPid)
        {
            if let hit = watcher.currentHit() {
                onBlocked?(hit, "send button")
                return nil
            }
            if let last = watcher.lastSightingDate, Date().timeIntervalSince(last) < 1.5 {
                let stale = Hit(evidence: .shortcode(":bagel-like:"), field: "(recent)")
                onBlocked?(stale, "send button (recent sighting)")
                return nil
            }
            let location = event.location
            if jevHolds(source: "send button", replay: { Self.replayClick(at: location) }) {
                return nil
            }
        }
        return pass
    }

    /// Whether to hold this send for Jev. A verdict from while typing answers at once; otherwise
    /// the send waits for Jev and is replayed if the message is fine. Jev being unreachable for 3
    /// seconds lets the send go, so a network outage doesn't stop Slack working.
    private func jevHolds(source: String, replay: @escaping () -> Void) -> Bool {
        guard jev.isAvailable, let snapshot = watcher.messageSnapshot(), !snapshot.isEmpty else { return false }
        if holding { return true }
        if let verdict = jev.cached(snapshot.key) {
            guard verdict.intercepts else { return false }
            onBlocked?(Hit(evidence: .jev(verdict.reason), field: snapshot.field), "\(source) (jev)")
            return true
        }
        holding = true
        var settled = false
        let finish: (JevVerdict?) -> Void = { [weak self] verdict in
            guard let self, !settled else { return }
            settled = true
            self.holding = false
            if let verdict, verdict.intercepts {
                self.onBlocked?(Hit(evidence: .jev(verdict.reason), field: snapshot.field), "\(source) (jev, held)")
            } else if self.watcher.slackIsFrontmost, self.watcher.messageSnapshot()?.key == snapshot.key {
                if verdict == nil { Log.write("jev: no verdict in time; letting the send through") }
                replay()
            }
        }
        jev.screen(snapshot, completion: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(nil) }
        return true
    }

    private static func replayReturn() {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Return), keyDown: down)
            event?.setIntegerValueField(.eventSourceUserData, value: replayMarker)
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func replayClick(at point: CGPoint) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.eventSourceUserData, value: replayMarker)
            event?.post(tap: .cghidEventTap)
        }
    }

    /// The pid owning the window under the pointer, from the window server: cheap, and it keeps
    /// clicks in other apps away from the accessibility hit test.
    private func windowOwner(under event: CGEvent) -> pid_t? {
        let window = CGWindowID(event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
        guard window != 0, let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]] else {
            return nil
        }
        return info.first?[kCGWindowOwnerPID as String] as? pid_t
    }

    private func clickIsOnSendButton(_ point: CGPoint, slackPid: pid_t) -> Bool {
        var element: AXUIElement?
        var pid: pid_t = 0
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
            let element, AXUIElementGetPid(element, &pid) == .success, pid == slackPid,
            let button = axAncestors(element, limit: 4).first(where: { (axAttr($0, kAXRoleAttribute) as String?) == kAXButtonRole })
        else { return false }
        return axLabel(button).lowercased().contains("send")
    }
}

// MARK: - Responses

enum Responder {
    /// Select all + delete in the focused field. Only sent while Slack is in front, so the keys go
    /// to its message box.
    static func clearFocusedField() {
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
        // Fallback: the system Lock Screen shortcut.
        press(kVK_ANSI_Q, [.maskCommand, .maskControl])
    }

    private static func press(_ key: Int, _ flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let watcher = SlackWatcher()
    let jev = JevGuard()
    lazy var interceptor = SendInterceptor(watcher: watcher, jev: jev)
    let overlay = OverlayController()
    var statusItem: NSStatusItem!
    /// Set from detection until the overlay is up, so a second report in between is ignored.
    var responding = false
    var reengageTimers: [Safeguard: Timer] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        for safeguard in Safeguard.allCases {
            // Turned off before re-engaging existed: start the clock now. Start at login is
            // opt-in, so it only comes back if it was turned off from the menu.
            if !safeguard.isEngaged, safeguard != .loginItem, Settings.reengageAt(safeguard) == nil {
                Settings.setReengageAt(safeguard, Date().addingTimeInterval(Settings.reengageAfter))
            }
            scheduleReengage(safeguard)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Keeps the spot the user ⌘-drags it to, so it can be moved clear of the notch once.
        statusItem.autosaveName = "BagelGuard"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        watcher.onHit = { [weak self] hit, source in self?.trigger(hit, source: source) }
        watcher.onApproach = { [weak self] in
            guard let self, Settings.mugshot, Settings.action.showsOverlay else { return }
            self.overlay.prewarmCamera()
        }
        interceptor.onBlocked = { [weak self] hit, source in
            // Called from inside the event tap; respond after the tap returns.
            DispatchQueue.main.async { self?.trigger(hit, source: source, blockedSend: true) }
        }
        overlay.onClose = { [weak self] in self?.watcher.forgetReported() }
        watcher.onContentSettled = { [weak self] snapshot in self?.screenWithJev(snapshot) }
        jev.start()

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            startGuards()
        } else {
            Log.write("waiting for Accessibility permission")
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.startGuards()
            }
        }
    }

    func startGuards() {
        Log.write("Accessibility granted; armed=\(Settings.armed) action=\(Settings.action.rawValue)")
        watcher.start()
        interceptor.start()
        refreshIcon()
        if Settings.mugshot {
            MugshotCamera.requestAccessIfNeeded()
            DispatchQueue.global(qos: .utility).async { MugshotCamera.warmUp() }
        }
        Lineup.shared.loadInBackground()
        if CommandLine.arguments.contains("--preview") { testOverlay() }
    }

    func trigger(_ hit: Hit, source: String, blockedSend: Bool = false) {
        guard !responding, !overlay.isShowing else { return }
        let detectedAt = Date()
        let action = Settings.action
        Log.write("BAGEL in \"\(hit.field)\": \(hit.evidence) (via \(source)\(blockedSend ? ", send blocked" : "")) -> \(action.rawValue)")
        guard action != .log else { return }

        let clearing = watcher.slackIsFrontmost
        if clearing { Responder.clearFocusedField() }
        if Settings.mugshot && action.showsOverlay { overlay.startCamera() }
        responding = true
        whenCleared(clearing, since: detectedAt) { [self] response in
            responding = false
            guard action.showsOverlay else { return Responder.lockScreen() }
            let booking = Booking(
                destination: Booking.destination(fromField: hit.field), evidence: hit.evidence.displayName,
                caseNumber: Settings.nextCaseNumber(), date: detectedAt, responseMilliseconds: response,
                ending: action == .overlayThenLock ? .lock : .close)
            overlay.show(booking, takePhoto: Settings.mugshot)
        }
    }

    /// Jev's check while typing: catches what the local rules can't name, such as a bagel emoji
    /// uploaded under another name, before anyone presses Return.
    func screenWithJev(_ snapshot: MessageSnapshot) {
        guard Settings.armed else { return }
        jev.screen(snapshot) { [weak self] verdict in
            guard let self, let verdict, verdict.intercepts,
                self.watcher.messageSnapshot()?.key == snapshot.key
            else { return }
            self.trigger(Hit(evidence: .jev(verdict.reason), field: snapshot.field), source: "jev")
        }
    }

    /// The clear goes through the HID queue to the frontmost app, so wait for Slack to apply it
    /// before the overlay takes focus (a Return typed meanwhile queues behind it). Calls `then` with
    /// the time to a confirmed empty box, or nil if it isn't confirmed within 0.3 s.
    private func whenCleared(_ clearing: Bool, since start: Date, then: @escaping (Int?) -> Void) {
        guard clearing else { return then(nil) }
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] timer in
            let elapsed = Date().timeIntervalSince(start)
            // A Jev catch has no local evidence to watch disappear, so wait for the box to empty.
            let cleared = self?.watcher.currentHit() == nil && self?.watcher.messageSnapshot()?.isEmpty ?? true
            guard cleared || elapsed > 0.3 else { return }
            timer.invalidate()
            then(cleared ? Int(elapsed * 1000) : nil)
        }
    }

    // MARK: Menu

    func refreshIcon() {
        if let iconPath = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png"),
           let image = NSImage(contentsOfFile: iconPath)
        {
            image.isTemplate = false
            image.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = "🥯"
        }
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
            menu.addItem(disabled: "Not watching Slack" + countdown(.armed))
        } else {
            menu.addItem(disabled: watcher.pid == nil ? "Waiting for Slack to open" : "Watching Slack for bagels")
        }
        menu.addItem(.separator())

        menu.addItem(checkbox: "Armed" + countdown(.armed), Settings.armed, #selector(toggleArmed))
        let actions = NSMenuItem(title: "When a bagel shows up", action: nil, keyEquivalent: "")
        actions.submenu = NSMenu()
        for action in Action.allCases {
            let title = action.title + (Settings.action == action ? countdown(.action) : "")
            let item = NSMenuItem(title: title, action: #selector(chooseAction(_:)), keyEquivalent: "")
            item.representedObject = action.rawValue
            item.state = Settings.action == action ? .on : .off
            actions.submenu?.addItem(item)
        }
        menu.addItem(actions)
        menu.addItem(checkbox: "Take a mugshot" + countdown(.mugshot), Settings.mugshot, #selector(toggleMugshot))
        menu.addItem(NSMenuItem(title: "Preview overlay", action: #selector(testOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open mugshots", action: #selector(openMugshots), keyEquivalent: ""))
        menu.addItem(.separator())

        menu.addItem(checkbox: "Start at login" + countdown(.loginItem), Safeguard.loginItem.isEngaged, #selector(toggleLoginItem))
        menu.addItem(NSMenuItem(title: "Open log", action: #selector(openLog), keyEquivalent: ""))
        menu.addItem(.separator())
        let minutes = Int(Settings.reengageAfter / 60)
        menu.addItem(NSMenuItem(title: "Quit BagelGuard (reopens in \(minutes) min)", action: #selector(quit), keyEquivalent: "q"))
    }

    /// " (back on in N min)" for a safeguard that is turned off, else "".
    func countdown(_ safeguard: Safeguard) -> String {
        guard let until = Settings.reengageAt(safeguard) else { return "" }
        let minutes = max(1, Int(ceil(until.timeIntervalSinceNow / 60)))
        return safeguard == .action ? " (overlay + lock again in \(minutes) min)" : " (back on in \(minutes) min)"
    }

    /// Applies a menu change and, if it turned a safeguard off, starts its re-engage clock. Switching
    /// between two "off" states (say, overlay only to log only) keeps the clock already running.
    func apply(_ safeguard: Safeguard, _ change: () -> Void) {
        change()
        if safeguard.isEngaged {
            Settings.setReengageAt(safeguard, nil)
        } else if Settings.reengageAt(safeguard) == nil {
            Settings.setReengageAt(safeguard, Date().addingTimeInterval(Settings.reengageAfter))
        }
        scheduleReengage(safeguard)
        refreshIcon()
    }

    /// Turns a safeguard back on when its pause runs out.
    func scheduleReengage(_ safeguard: Safeguard) {
        reengageTimers.removeValue(forKey: safeguard)?.invalidate()
        guard !safeguard.isEngaged, let deadline = Settings.reengageAt(safeguard) else {
            Settings.setReengageAt(safeguard, nil)
            return
        }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            self?.reengageTimers[safeguard] = nil
            Settings.setReengageAt(safeguard, nil)
            safeguard.engage()
            Log.write("\(safeguard.rawValue) re-engaged")
            self?.refreshIcon()
        }
        RunLoop.main.add(timer, forMode: .common)
        reengageTimers[safeguard] = timer
    }

    @objc func toggleArmed() {
        OwnerCheck.require(Settings.armed ? "disarm BagelGuard" : "arm BagelGuard") { [weak self] in
            self?.apply(.armed) { Settings.armed.toggle() }
            Log.write("armed=\(Settings.armed)")
        }
    }

    @objc func chooseAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = Action(rawValue: raw),
              action != Settings.action
        else { return }
        OwnerCheck.require("change what BagelGuard does on a catch") { [weak self] in
            self?.apply(.action) { Settings.action = action }
            Log.write("action=\(action.rawValue)")
        }
    }

    @objc func testOverlay() {
        overlay.show(.sample(.preview), takePhoto: Settings.mugshot)
    }

    @objc func toggleMugshot() {
        OwnerCheck.require(Settings.mugshot ? "turn off BagelGuard's mugshot" : "turn on BagelGuard's mugshot") { [weak self] in
            self?.apply(.mugshot) { Settings.mugshot.toggle() }
            if Settings.mugshot { MugshotCamera.requestAccessIfNeeded() }
        }
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
        let enabled = SMAppService.mainApp.status == .enabled
        OwnerCheck.require(enabled ? "stop BagelGuard starting at login" : "start BagelGuard at login") { [weak self] in
            self?.apply(.loginItem) {
                do {
                    if enabled {
                        try SMAppService.mainApp.unregister()
                    } else {
                        try SMAppService.mainApp.register()
                    }
                } catch {
                    Log.write("login item change failed: \(error)")
                }
            }
        }
    }

    /// Quitting is the easiest way to disarm, so it needs the owner too, and a detached shell
    /// reopens the app once the pause is over.
    @objc func quit() {
        OwnerCheck.require("quit BagelGuard") {
            let reopen = Process()
            reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
            reopen.arguments = ["-c", "sleep \(Int(Settings.reengageAfter)); exec /usr/bin/open -g \"$0\"", Bundle.main.bundlePath]
            do { try reopen.run() } catch { Log.write("couldn't schedule reopen: \(error)") }
            Log.write("quit; reopening in \(Int(Settings.reengageAfter / 60)) min")
            NSApp.terminate(nil)
        }
    }
}

extension NSMenu {
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }

    func addItem(checkbox title: String, _ on: Bool, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.state = on ? .on : .off
        addItem(item)
    }
}

Settings.register()
DevTools.runIfRequested()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
