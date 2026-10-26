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

/// Security-critical settings. These live in the signed `SecureStore`, not plain UserDefaults, so a
/// `defaults write` can't disarm BagelGuard behind the Touch ID the menu requires. The counters that
/// don't affect security (the case number) stay in ordinary defaults.
enum Settings {
    static let defaults = UserDefaults.standard

    static func register() {
        SecureStore.boot()
        if SecureStore.wasTampered {
            Log.write("settings: signature mismatch — someone edited the store outside the app; failing closed to armed")
        }
    }

    static var armed: Bool {
        get { SecureStore.bool("armed", default: true) }
        set { SecureStore.set("armed", newValue) }
    }

    /// Whether the overlay takes a webcam photo of whoever tried.
    static var mugshot: Bool {
        get { SecureStore.bool("mugshot", default: true) }
        set { SecureStore.set("mugshot", newValue) }
    }

    static var action: Action {
        get { Action(rawValue: SecureStore.string("action") ?? "") ?? .overlayThenLock }
        set { SecureStore.set("action", newValue.rawValue) }
    }

    /// Counts caught attempts; shown as the case number on the overlay. Not security-critical.
    static func nextCaseNumber() -> Int {
        let next = defaults.integer(forKey: "caseCount") + 1
        defaults.set(next, forKey: "caseCount")
        return next
    }

    /// Turning any safeguard off is a pause: it turns itself back on after this long.
    static let reengageAfter: TimeInterval = 3 * 60

    /// When a turned-off safeguard comes back on. Persisted (signed) so a relaunch doesn't extend the
    /// pause, and clamped on read to at most `reengageAfter` from now, so a pre-planted far-future
    /// date can't keep a safeguard off.
    static func reengageAt(_ safeguard: Safeguard) -> Date? {
        guard let epoch = SecureStore.double("reengageAt.\(safeguard.rawValue)") else { return nil }
        let date = Date(timeIntervalSince1970: epoch)
        let cap = Date().addingTimeInterval(reengageAfter)
        return min(date, cap)
    }

    static func setReengageAt(_ safeguard: Safeguard, _ date: Date?) {
        SecureStore.set("reengageAt.\(safeguard.rawValue)", date?.timeIntervalSince1970)
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

/// Whether the login window is covering the session (screen locked).
func screenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return session["CGSSessionScreenIsLocked"] as? Bool ?? false
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
    /// The face at the camera when sending, e.g. "face is Jane Doe, not Thomas Ip".
    case face(String)

    var description: String {
        switch self {
        case .character: return "unicode 🥯"
        case .shortcode(let text): return "shortcode \(text)"
        case .word(let text): return "text \"\(text)\""
        case .emoji(let label): return "emoji image \"\(label)\""
        case .jev(let reason): return "jev: \(reason)"
        case .face(let reason): return "face check: \(reason)"
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
        case .face(let reason): return reason
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
    /// The word, or spelled backwards.
    static let word = try! NSRegularExpression(pattern: "bagel|legab", options: [.caseInsensitive])
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
        // Run the regexes on the normalized text too, so lookalike letters and spacing don't dodge them.
        let normal = Text.normalized(text)
        if let match = first(shortcode, in: text) ?? first(shortcode, in: normal) { return .shortcode(match) }
        guard plainText else { return nil }
        if let match = first(word, in: text) ?? first(word, in: normal) { return .word(match) }
        if let match = first(EmojiBook.shared.namesPattern, in: text) { return .word(match) }
        if let found = Text.hiddenBagel(in: text) { return .word(found) }
        return nil
    }

    /// Slack turns a finished emoji into an AXImage inside the message box, labelled e.g. "bagel
    /// emoji" or "bagel pet emoji".
    /// Also counts emoji whose picture Jev judged to be a bagel, whatever they're called.
    static func scanImages(in root: AXUIElement) -> Evidence? {
        for image in images(in: root) {
            if image.label.lowercased().contains("bagel") { return .emoji(image.label) }
            if EmojiBook.shared.looksLikeBagel(image.label) { return .emoji("\(image.label), looks like a bagel") }
        }
        return nil
    }

    /// The emoji images in the box, in reading order, with where each is on screen.
    static func images(in root: AXUIElement) -> [(label: String, frame: CGRect?)] {
        var found: [(label: String, frame: CGRect?)] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast(), visited < 400 {
            visited += 1
            if (axAttr(element, kAXRoleAttribute) as String?) == kAXImageRole {
                found.append((axLabel(element), axFrame(element)))
            }
            if depth < 8 { stack.append(contentsOf: axChildren(element).reversed().map { ($0, depth + 1) }) }
        }
        return found
    }

    /// A bagel in a message's text or emoji labels, wherever that text came from (the composer, an
    /// edit box, or a message already sent).
    static func evidence(text: String, emojiLabels: [String], plainText: Bool) -> Evidence? {
        if let found = scan(text, plainText: plainText) { return found }
        for label in emojiLabels {
            if label.lowercased().contains("bagel") { return .emoji(label) }
            if EmojiBook.shared.looksLikeBagel(label) { return .emoji("\(label), looks like a bagel") }
        }
        return nil
    }

    /// The message box (a text area) the focused node sits in, if any.
    static func messageBox(focused: AXUIElement) -> AXUIElement? {
        axAncestors(focused, limit: 6).first { (axAttr($0, kAXRoleAttribute) as String?) == kAXTextAreaRole }
    }

    private static func first(_ regex: NSRegularExpression?, in text: String) -> String? {
        guard let regex, let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
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
    /// A message went out: the box went from holding this to empty. Seen from Slack's own tree, so
    /// it works when the event tap is blind (Secure Keyboard Entry stuck on after a screen lock).
    var onSent: ((MessageSnapshot, Date) -> Void)?
    /// Whether Slack is in front (and the screen unlocked), on every poll.
    var onSlackActive: ((Bool) -> Void)?
    /// What the focused message box last held, while it held anything.
    private var lastContent: MessageSnapshot?
    /// When `lastContent` was last seen in the box: the send happened just after.
    private var lastContentAt = Date.distantPast
    private var emojiScanTimer: Timer?
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
        // Chromium doesn't post an AX notification for every edit, so also poll while Slack is in front.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let pid = self.pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                !screenIsLocked()
            else {
                self?.onSlackActive?(false)
                return
            }
            self.onSlackActive?(Settings.armed)
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
        let images = Detector.images(in: box)
        return MessageSnapshot(
            text: axAttr(box, kAXValueAttribute) ?? "", emojiLabels: images.map(\.label),
            emojiFrames: images.map { $0.frame ?? .zero }, field: axLabel(box), frame: axFrame(box))
    }

    /// The text the focused element (or an ancestor) holds, whatever kind of element it is: Slack's
    /// inline message editor isn't a text area like the composer.
    func focusedTextSnapshot() -> MessageSnapshot? {
        guard let app, let focused = axElement(app, kAXFocusedUIElementAttribute) else { return nil }
        let skipped: Set<String> = [kAXCheckBoxRole, kAXRadioButtonRole, kAXSliderRole, kAXButtonRole, kAXScrollBarRole]
        for node in axAncestors(focused, limit: 8) {
            guard let role: String = axAttr(node, kAXRoleAttribute), !skipped.contains(role),
                let value: String = axAttr(node, kAXValueAttribute),
                !value.trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{FFFC}"])).isEmpty
            else { continue }
            let images = Detector.images(in: node)
            return MessageSnapshot(
                text: value, emojiLabels: images.map(\.label), emojiFrames: images.map { $0.frame ?? .zero },
                field: axLabel(node), frame: axFrame(node))
        }
        return nil
    }

    /// The message focused in the conversation (Up from an empty composer focuses your last one):
    /// its text and emoji, read from the whole message row, sender and time included.
    func focusedMessage() -> (text: String, emojiLabels: [String])? {
        guard let app, let focused = axElement(app, kAXFocusedUIElementAttribute),
            (axAttr(focused, kAXRoleAttribute) as String?) != kAXTextAreaRole,
            axAncestors(focused, limit: 4).dropFirst().contains(where: { (axAttr($0, kAXRoleAttribute) as String?) == kAXListRole })
        else { return nil }
        var texts: [String] = []
        var labels: [String] = []
        var stack: [(AXUIElement, Int)] = [(focused, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast(), visited < 300 {
            visited += 1
            let role: String? = axAttr(element, kAXRoleAttribute)
            if role == kAXImageRole {
                labels.append(axLabel(element))
            } else if role == kAXStaticTextRole, let value: String = axAttr(element, kAXValueAttribute) {
                texts.append(value)
            }
            if depth < 12 { stack.append(contentsOf: axChildren(element).reversed().map { ($0, depth + 1) }) }
        }
        return (texts.joined(separator: " "), labels)
    }

    /// The focused element's role chain, nearest first, for diagnostics.
    func focusedRoles() -> String {
        guard let app, let focused = axElement(app, kAXFocusedUIElementAttribute) else { return "nothing focused" }
        return axAncestors(focused, limit: 8).map { (axAttr($0, kAXRoleAttribute) as String?) ?? "?" }.joined(separator: " < ")
    }

    /// The bagel currently in Slack's focused field, if any.
    func currentHit() -> Hit? {
        if case .bagel(let hit) = observeFocused() { return hit }
        return nil
    }

    func check(source: String) {
        guard Settings.armed else { return }
        var observation = observeFocused()
        // Editing a message already sent (Up, then retype) happens in Slack's inline editor, which
        // isn't the composer text area, so `observe` misses it. Scan that editor too.
        if case .clean = observation, messageSnapshot() == nil, let editing = focusedTextSnapshot(),
            let evidence = Detector.evidence(text: editing.text, emojiLabels: editing.emojiLabels, plainText: true)
        {
            observation = .bagel(Hit(evidence: evidence, field: editing.field))
        }
        if case .bagel = observation {
            lastContent = nil  // being dealt with; its clearing isn't a send
        } else {
            noteContent()
        }
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
        }
    }

    /// Tracks the message box to spot sends, and has new emoji in it judged by picture.
    private func noteContent() {
        guard let snapshot = messageSnapshot() else {
            lastContent = nil
            return
        }
        if !snapshot.isEmpty {
            lastContent = snapshot
            lastContentAt = Date()
            let emoji = zip(snapshot.emojiLabels, snapshot.emojiFrames).map { (label: $0, frame: $1) }
            EmojiBook.shared.learn(emoji) { [weak self] bagels in
                if !bagels.isEmpty { self?.check(source: "emoji book") }
            }
            return
        }
        guard let sent = lastContent, sent.field == snapshot.field else { return }
        let sentAt = lastContentAt
        lastContent = nil
        // Confirm a moment later, so a flicker in Slack's tree isn't taken for a send.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.lastContent == nil, self.messageSnapshot()?.isEmpty != false else { return }
            self.onSent?(sent, sentAt)
        }
    }

    /// Has the emoji on screen in Slack judged in the background, so an emoji seen before (in
    /// someone's message, say) is already known when it's typed.
    func startEmojiScan() {
        emojiScanTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self, Settings.armed, self.slackIsFrontmost else { return }
            let visible = self.visibleEmoji().filter { !EmojiBook.shared.isKnown($0.label) }
            if !visible.isEmpty { EmojiBook.shared.learn(visible) }
        }
    }

    private func visibleEmoji() -> [(label: String, frame: CGRect)] {
        guard let app, let window = axElement(app, kAXFocusedWindowAttribute) else { return [] }
        var found: [(label: String, frame: CGRect)] = []
        var stack = [window]
        var visited = 0
        while let element = stack.popLast(), visited < 2500 {
            visited += 1
            if (axAttr(element, kAXRoleAttribute) as String?) == kAXImageRole {
                let label = axLabel(element)
                if label.hasSuffix(" emoji"), !label.lowercased().contains("bagel"),
                    let frame = axFrame(element), frame.width >= 16, frame.height >= 16
                {
                    found.append((label, frame))
                }
            }
            stack.append(contentsOf: axChildren(element))
        }
        return found
    }

    /// Presses the button with this label in Slack's focused window, e.g. a dialog's "Delete".
    func pressButton(named name: String) -> Bool {
        guard let app, let window = axElement(app, kAXFocusedWindowAttribute) else { return false }
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let element = queue.removeFirst()
            visited += 1
            if (axAttr(element, kAXRoleAttribute) as String?) == kAXButtonRole,
                axLabel(element).caseInsensitiveCompare(name) == .orderedSame
            {
                return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            }
            queue.append(contentsOf: axChildren(element))
        }
        return false
    }

    /// Report a bagel still in the box again, e.g. after the overlay closes without it being cleared.
    func forgetReported() {
        reported = nil
    }
}

// MARK: - Send interception (event tap)

/// Marks keystrokes and clicks BagelGuard posts itself (replayed sends, the delete sequence), so the
/// event tap lets them through.
let syntheticEventMarker: Int64 = 0x6261_6765_6C

/// Swallows Return and clicks on Slack's Send button while a bagel is in the message box. This is
/// a backstop: detection normally clears the box first. While any app holds Secure Keyboard Entry
/// the tap receives no keystrokes, so only the Send-button check works then. (macOS sometimes
/// leaves the login window holding it after a screen unlock; sends are then caught after the fact.)
final class SendInterceptor {
    private var tap: CFMachPort?
    let watcher: SlackWatcher
    let jev: JevGuard
    var onBlocked: ((Hit, String) -> Void)?
    /// A send just happened, with this content, seen at the keystroke (reliable even when a fast send
    /// outruns the poll). The content is judged, and deleted if it's a bagel or doesn't pass.
    var onSendAttempt: ((MessageSnapshot) -> Void)?
    /// Why the person at the keyboard may not send, or nil if they may (the face check).
    var sendRefusal: (() -> String?)?
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
        guard event.getIntegerValueField(.eventSourceUserData) != syntheticEventMarker else { return pass }
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
            guard !event.flags.contains(.maskShift) else { return pass }
            if let hit = refusedSend() {
                onBlocked?(hit, "return key")
                return nil
            }
            // Capture the box now, at the keystroke, so even a send too fast for the 0.25 s poll to
            // have seen gets judged (and deleted) afterwards.
            if let snap = watcher.messageSnapshot() ?? watcher.focusedTextSnapshot(), !snap.isEmpty {
                onSendAttempt?(snap)
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
            if let hit = refusedSend() {
                onBlocked?(hit, "send button")
                return nil
            }
            if let snap = watcher.messageSnapshot() ?? watcher.focusedTextSnapshot(), !snap.isEmpty {
                onSendAttempt?(snap)
            }
        }
        return pass
    }

    /// A send from the composer, or a save of an edited message, with something in it, by someone the
    /// face check doesn't pass.
    private func refusedSend() -> Hit? {
        guard let snapshot = watcher.messageSnapshot() ?? watcher.focusedTextSnapshot(), !snapshot.isEmpty,
            let refusal = sendRefusal?() else { return nil }
        return Hit(evidence: .face(refusal), field: snapshot.field)
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

    /// Deletes your last message in the focused conversation through Slack's own UI, since there's
    /// no Slack token to call chat.delete with: Up edits the last message, saving it empty asks to
    /// delete it, and the dialog's Delete confirms. Leaves it alone unless the message opened for
    /// editing holds what was flagged.
    static func deleteLastMessage(matching expected: MessageSnapshot, watcher: SlackWatcher, done: @escaping (Bool) -> Void) {
        guard watcher.slackIsFrontmost, watcher.messageSnapshot()?.isEmpty == true else { return done(false) }
        press(kVK_UpArrow)
        // Depending on Slack's settings, Up either focuses your last message or opens it for editing.
        poll(every: 0.1, upTo: 1.5, until: { watcher.focusedMessage() != nil || watcher.focusedTextSnapshot() != nil }) { found in
            if watcher.focusedMessage() != nil {
                // A later message may have been sent right after (the "send, then lgtm" dodge), so
                // the flagged one isn't necessarily the one Up focused. Walk up recent messages,
                // newest first, until it's found.
                return searchUpward(matching: expected, watcher: watcher, remaining: 6, done: done)
            }
            if let editing = watcher.focusedTextSnapshot(), editing.sameContent(as: expected) {
                // Saving an emptied edit asks to delete.
                press(kVK_ANSI_A, .maskCommand)
                press(kVK_Delete)
                return after(0.2) {
                    press(kVK_Return)
                    confirmDelete(watcher: watcher, done: done)
                }
            }
            Log.write("delete: after Up, focus is \(watcher.focusedRoles()); leaving it")
            if found { press(kVK_Escape) }
            done(false)
        }
    }

    /// Clears the composer, waits for it to empty, then deletes any bagel that had already been sent.
    static func clearAndDeleteSentBagel(watcher: SlackWatcher, done: @escaping (Bool) -> Void) {
        if watcher.messageSnapshot()?.isEmpty == false { clearFocusedField() }
        poll(every: 0.05, upTo: 0.5, until: { watcher.messageSnapshot()?.isEmpty != false }) { _ in
            deleteJustSentBagel(watcher: watcher, done: done)
        }
    }

    /// Deletes a bagel that was sent before detection could clear it: walks the most recent messages,
    /// newest first, and removes the first one that is a bagel. Only touches bagel messages.
    static func deleteJustSentBagel(watcher: SlackWatcher, done: @escaping (Bool) -> Void) {
        guard watcher.slackIsFrontmost, watcher.messageSnapshot()?.isEmpty != false else { return done(false) }
        press(kVK_UpArrow)
        poll(every: 0.1, upTo: 1.5, until: { watcher.focusedMessage() != nil }) { found in
            guard found else {
                Log.write("delete sent bagel: no message focused after Up (\(watcher.focusedRoles()))")
                return done(false)
            }
            deleteBagelUpward(watcher: watcher, remaining: 4, done: done)
        }
    }

    private static func deleteBagelUpward(watcher: SlackWatcher, remaining: Int, done: @escaping (Bool) -> Void) {
        guard let message = watcher.focusedMessage() else {
            press(kVK_Escape)
            return done(false)
        }
        if Detector.evidence(text: message.text, emojiLabels: message.emojiLabels, plainText: true) != nil {
            press(kVK_Delete)
            return confirmDelete(watcher: watcher, done: done)
        }
        guard remaining > 0 else {
            press(kVK_Escape)
            return done(false)
        }
        press(kVK_UpArrow)
        after(0.12) { deleteBagelUpward(watcher: watcher, remaining: remaining - 1, done: done) }
    }

    /// With a message focused, deletes it if it's the flagged one, else moves up to the previous
    /// message and tries again, up to `remaining` times.
    private static func searchUpward(matching expected: MessageSnapshot, watcher: SlackWatcher, remaining: Int, done: @escaping (Bool) -> Void) {
        guard let message = watcher.focusedMessage() else {
            press(kVK_Escape)
            return done(false)
        }
        if contains(message, expected) {
            press(kVK_Delete)  // Slack's delete shortcut on a focused message; it asks to confirm
            return confirmDelete(watcher: watcher, done: done)
        }
        guard remaining > 0 else {
            Log.write("delete: flagged message (\(expected.text.count) chars, emoji \(expected.emojiLabels)) not among recent messages; leaving it")
            press(kVK_Escape)
            return done(false)
        }
        press(kVK_UpArrow)  // move selection to the previous message
        after(0.12) {
            searchUpward(matching: expected, watcher: watcher, remaining: remaining - 1, done: done)
        }
    }

    /// Whether a focused message row holds the flagged text and emoji (the row adds the sender,
    /// time and status emoji around them).
    private static func contains(_ message: (text: String, emojiLabels: [String]), _ expected: MessageSnapshot) -> Bool {
        func normal(_ s: String) -> String { s.filter { !$0.isWhitespace && $0 != "\u{FFFC}" }.lowercased() }
        let wanted = normal(expected.text)
        return (wanted.isEmpty || normal(message.text).contains(wanted))
            && Set(expected.emojiLabels).isSubset(of: Set(message.emojiLabels))
            && !(wanted.isEmpty && expected.emojiLabels.isEmpty)
    }

    /// Presses Delete in Slack's confirmation dialog once it shows.
    private static func confirmDelete(watcher: SlackWatcher, done: @escaping (Bool) -> Void) {
        poll(every: 0.15, upTo: 2, until: { watcher.pressButton(named: "Delete") }) { pressed in
            if !pressed {
                Log.write("delete: no Delete button found; pressing Return")
                press(kVK_Return)
            }
            after(0.4) {
                press(kVK_Escape)  // focus back to the composer
                done(true)
            }
        }
    }

    /// Checks `condition` every `interval` until it holds or `limit` seconds pass.
    private static func poll(every interval: Double, upTo limit: Double, until condition: @escaping () -> Bool, then: @escaping (Bool) -> Void) {
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            let met = condition()
            guard met || Date().timeIntervalSince(started) > limit else { return }
            timer.invalidate()
            then(met)
        }
    }

    private static func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
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
            event?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let watcher = SlackWatcher()
    let jev = JevGuard()
    let faceWatch = FaceWatch()
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
        watcher.onSent = { [weak self] sent, sentAt in self?.judgeSent(sent, sentAt: sentAt) }
        // Fires from the event tap at the Return/Send keystroke, so a send too fast for the poll is
        // still judged. Give Slack a moment to actually send, then run the same checks.
        interceptor.onSendAttempt = { [weak self] sent in
            let at = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.judgeSent(sent, sentAt: at) }
        }
        // The camera runs while Slack is in front, so the owner is already recognised by the time
        // they click into a box and send.
        watcher.onSlackActive = { [weak self] active in
            guard let self else { return }
            // The overlay's mugshot needs the camera; the watch resumes once it's gone.
            if active, !self.responding, !self.overlay.isShowing {
                self.faceWatch.start()
            } else if screenIsLocked() {
                self.faceWatch.stopNow()
            } else if !active {
                self.faceWatch.stop()
            }
        }
        faceWatch.onStranger = { [weak self] name in self?.strangerAtKeyboard(name) }
        interceptor.sendRefusal = { [weak self] in self?.faceWatch.refusalBeforeSend }
        EmojiBook.shared.jev = jev
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
        watcher.startEmojiScan()
        interceptor.start()
        refreshIcon()
        if Settings.mugshot {
            MugshotCamera.requestAccessIfNeeded()
            DispatchQueue.global(qos: .utility).async { MugshotCamera.warmUp() }
        }
        Lineup.shared.loadInBackground()
        if CommandLine.arguments.contains("--preview") { testOverlay() }
    }

    /// `clearBox` is false for a message already sent: the box is empty, and focus may still be on
    /// a message, where Cmd-A + Delete would ask to delete it.
    func trigger(_ hit: Hit, source: String, blockedSend: Bool = false, clearBox: Bool = true) {
        guard !responding, !overlay.isShowing else { return }
        let action = Settings.action
        Log.write("BAGEL in \"\(hit.field)\": \(hit.evidence) (via \(source)\(blockedSend ? ", send blocked" : "")) -> \(action.rawValue)")
        guard action != .log else { return }

        // A bagel caught in the composer may already have been sent a frame before the AX
        // notification reached us (the box can even still read non-empty from AX lag). So clear the
        // box and, either way, delete any copy that already went out — the delete only removes a
        // message that is itself a bagel, so it does nothing when nothing was sent.
        let contentBagel: Bool = { if case .face = hit.evidence { return false } else { return true } }()
        if clearBox, contentBagel, watcher.slackIsFrontmost {
            responding = true
            Responder.clearAndDeleteSentBagel(watcher: watcher) { [weak self] deleted in
                if deleted { Log.write("deleted a bagel that had already been sent") }
                self?.responding = false
                self?.respond(to: hit, action: action, clearBox: false)
            }
            return
        }
        respond(to: hit, action: action, clearBox: clearBox)
    }

    /// Clears the box (when the bagel is still in it), shows the overlay and locks.
    func respond(to hit: Hit, action: Action, clearBox: Bool) {
        guard !responding, !overlay.isShowing else { return }
        let detectedAt = Date()
        if Settings.mugshot && action.showsOverlay { faceWatch.stopNow() }
        let clearing = clearBox && watcher.slackIsFrontmost
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

    /// Every sent message is checked after the fact: its emoji against the emoji book (one judged
    /// just now may have missed the box), and its text by Jev. A flagged message is deleted, then
    /// handled like any other catch.
    private var recentlyJudged: [String: Date] = [:]

    func judgeSent(_ sent: MessageSnapshot, sentAt: Date) {
        guard Settings.armed, !sent.isEmpty, !responding, !overlay.isShowing else { return }
        // The tap path and the poll path can both report one send; judge each content once per few seconds.
        let now = Date()
        recentlyJudged = recentlyJudged.filter { now.timeIntervalSince($0.value) < 3 }
        if let last = recentlyJudged[sent.key], now.timeIntervalSince(last) < 3 { return }
        recentlyJudged[sent.key] = now
        faceWatch.verdict(forSendAt: sentAt) { [weak self] refusal, summary in
            guard let self else { return }
            Log.write("face check on send: \(refusal ?? "passed") (\(summary))")
            if let refusal { return self.flagSent(sent, .face(refusal)) }
            self.judgeContent(sent)
        }
    }

    private func judgeContent(_ sent: MessageSnapshot) {
        let bagelEmoji = { sent.emojiLabels.first(where: EmojiBook.shared.looksLikeBagel) }
        if let label = bagelEmoji() {
            return flagSent(sent, .emoji("\(label), looks like a bagel"))
        }
        // The local rules again, in case the box was sent before a check saw it.
        if let evidence = Detector.scan(sent.text, plainText: true) {
            return flagSent(sent, evidence)
        }
        if sent.emojiLabels.contains(where: { !EmojiBook.shared.isJudged($0) }) {
            // An emoji still being judged: look again once the answer is in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if let label = bagelEmoji() { self?.flagSent(sent, .emoji("\(label), looks like a bagel")) }
            }
        }
        jev.judge(sent) { [weak self] outcome in
            switch outcome {
            case .verdict(let verdict):
                if verdict.intercepts { self?.flagSent(sent, .jev(verdict.reason)) }
            case .unreachable:
                // The content filter is required but couldn't run: by "pass both checks", a message
                // it couldn't clear doesn't go out. (Disarm with Touch ID to send while offline.)
                self?.flagSent(sent, .jev("couldn't be screened (Jev unreachable)"))
            case .off:
                break  // no key configured: the Jev filter isn't set up
            }
        }
    }

    /// Someone other than the owner is at the camera while a message is being written: deal with
    /// it before they can send.
    func strangerAtKeyboard(_ name: String?) {
        guard Settings.armed, watcher.slackIsFrontmost, let snapshot = watcher.messageSnapshot(), !snapshot.isEmpty,
            let refusal = faceWatch.refusalBeforeSend
        else { return }
        trigger(Hit(evidence: .face(refusal), field: snapshot.field), source: "face watch")
    }

    private var lastFlagged: String?

    private func flagSent(_ sent: MessageSnapshot, _ evidence: Evidence) {
        guard lastFlagged != sent.key, !responding, !overlay.isShowing else { return }
        lastFlagged = sent.key
        let hit = Hit(evidence: evidence, field: sent.field)
        Log.write("sent message flagged in \"\(hit.field)\" (\(evidence)); deleting it")
        Responder.deleteLastMessage(matching: sent, watcher: watcher) { [weak self] deleted in
            Log.write(deleted ? "deleted the flagged message" : "flagged message NOT deleted")
            self?.trigger(hit, source: deleted ? "sent, then deleted" : "sent, not deleted", clearBox: false)
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
        let enroll = Lineup.shared.isOwnerEnrolled ? "Re-enroll my face for sending" : "Enroll my face for sending…"
        menu.addItem(NSMenuItem(title: enroll, action: #selector(enrollFace), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Preview overlay", action: #selector(testOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open mugshots", action: #selector(openMugshots), keyEquivalent: ""))
        menu.addItem(.separator())

        menu.addItem(checkbox: "Start at login" + countdown(.loginItem), Safeguard.loginItem.isEngaged, #selector(toggleLoginItem))
        menu.addItem(checkbox: "Relaunch if force-quit", WatchdogAgent.isInstalled, #selector(toggleWatchdog))
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

    private var enrollCamera: MugshotCamera?

    /// Captures one camera frame behind Touch ID and stores the owner's face embedding, so the face
    /// check no longer depends on the swappable lineup photo file.
    @objc func enrollFace() {
        OwnerCheck.require("enrol your face as the owner") { [weak self] in
            guard MugshotCamera.isAuthorized else { return self?.enrollResult(false, "Camera access is off.") ?? () }
            self?.faceWatch.stopNow()  // free the camera
            let cam = MugshotCamera()
            self?.enrollCamera = cam
            cam.snap(onPhoto: { [weak self] mugshot in
                guard let image = mugshot?.rawImage ?? mugshot?.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    return self?.enrollResult(false, "Couldn't get a camera frame.") ?? ()
                }
                Lineup.shared.enrollOwner(from: image) { [weak self] ok in
                    self?.enrollCamera = nil
                    self?.enrollResult(ok, ok ? "Your face is enrolled. Only you can send now." : "No clear face found — try again, facing the camera in good light.")
                }
            }, onAnalyzed: { _ in })
        }
    }

    private func enrollResult(_ ok: Bool, _ message: String) {
        Log.write("enroll: \(ok ? "ok" : "failed") — \(message)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = ok ? "Face enrolled" : "Enrollment didn't work"
        alert.informativeText = message
        alert.runModal()
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

    /// A LaunchAgent that brings BagelGuard back if someone force-quits it (`killall`, Activity
    /// Monitor). Installing or removing it needs Touch ID, like any other weakening.
    @objc func toggleWatchdog() {
        let installed = WatchdogAgent.isInstalled
        OwnerCheck.require(installed ? "stop BagelGuard relaunching itself" : "let BagelGuard relaunch itself if force-quit") {
            installed ? WatchdogAgent.uninstall() : WatchdogAgent.install()
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
