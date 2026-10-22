// Tamper-evident storage for the settings that matter for security (armed, catch action, the
// re-engage clocks, the emoji book). Plain `defaults write` can turn those off without the Touch ID
// the menu demands, so they live in a blob signed with a key kept in the Keychain. While the app
// runs, the values are held in memory and never re-read from disk, so an external write is ignored;
// across a relaunch the signature is checked, and anything tampered with or deleted fails closed to
// the safe default.

import CryptoKit
import Foundation

enum SecureStore {
    private static let blobKey = "secureState.blob"
    private static let sigKey = "secureState.sig"
    private static let defaults = UserDefaults.standard
    private static let lock = NSLock()
    private static var state: [String: Any] = [:]
    private static var loaded = false

    /// True when the stored blob existed but its signature didn't verify: someone changed it outside
    /// the app. The caller logs it once.
    private(set) static var wasTampered = false

    // MARK: Keychain-held HMAC key

    private static let keyTag = "com.thomasip.bagelguard.statekey".data(using: .utf8)!

    private static let hmacKey: SymmetricKey = {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.thomasip.bagelguard",
            kSecAttrAccount as String: "state-hmac",
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        var add = query
        add.removeValue(forKey: kSecReturnData as String)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
        return key
    }()

    private static func sign(_ data: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: hmacKey)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Load / save

    /// Reads and verifies the blob once. Call before first use.
    static func boot() {
        lock.lock(); defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        guard let blob = defaults.data(forKey: blobKey) else { return }  // first run: empty, defaults apply
        guard let sig = defaults.string(forKey: sigKey), sign(blob) == sig,
            let dict = (try? JSONSerialization.jsonObject(with: blob)) as? [String: Any]
        else {
            wasTampered = true
            return  // leave state empty: every getter falls back to its safe default
        }
        state = dict
    }

    private static func persist() {
        guard let blob = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        defaults.set(blob, forKey: blobKey)
        defaults.set(sign(blob), forKey: sigKey)
    }

    // MARK: Typed access

    static func bool(_ key: String, default fallback: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state[key] as? Bool ?? fallback
    }

    static func string(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return state[key] as? String
    }

    static func double(_ key: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return state[key] as? Double
    }

    static func dictionary(_ key: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return state[key] as? [String: Any]
    }

    static func set(_ key: String, _ value: Any?) {
        lock.lock(); defer { lock.unlock() }
        if let value { state[key] = value } else { state.removeValue(forKey: key) }
        persist()
    }
}

// MARK: - Watchdog

/// A LaunchAgent that relaunches BagelGuard if it is killed (but not when it exits cleanly, so the
/// Touch ID quit still works). `killall BagelGuard` otherwise leaves it dead until next login. This
/// is installed and removed only behind Touch ID, from the menu, because managing launchd affects
/// how the app runs on the machine.
enum WatchdogAgent {
    static let label = "com.thomasip.bagelguard.watchdog"
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// The binary inside the running app bundle, so a relaunch runs this build.
    private static var binaryPath: String { Bundle.main.executableURL?.path ?? "" }

    static func install() {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryPath],
            "KeepAlive": ["SuccessfulExit": false],  // relaunch on a kill/crash, not a clean quit
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "EnvironmentVariables": ["BAGELGUARD_MANAGED": "1"],
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
            launchctl("bootout")  // drop any older copy, ignore if absent
            launchctl("bootstrap")
            Log.write("watchdog: installed")
        } catch {
            Log.write("watchdog: install failed: \(error.localizedDescription)")
        }
    }

    static func uninstall() {
        launchctl("bootout")
        try? FileManager.default.removeItem(at: plistURL)
        Log.write("watchdog: removed")
    }

    private static func launchctl(_ verb: String) {
        let uid = getuid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = verb == "bootstrap"
            ? ["bootstrap", "gui/\(uid)", plistURL.path]
            : ["bootout", "gui/\(uid)/\(label)"]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
