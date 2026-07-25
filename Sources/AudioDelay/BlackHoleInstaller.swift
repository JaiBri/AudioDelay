import AppKit
import CryptoKit
import Foundation

// AudioDelay cannot ship BlackHole itself. The source is GPLv3, but Existential Audio
// reserves all rights over their compiled installers, so redistributing the binary is
// not permitted. Instead the app fetches that same official installer on first launch
// and runs it, which keeps the user to a single download and keeps us within the
// license. The version and checksum are pinned so a compromised or swapped file is
// rejected rather than installed.
enum BlackHoleInstaller {
    static let version = "0.7.1"
    static let deviceName = "BlackHole 2ch"
    static let downloadURL = URL(string: "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg")!
    static let expectedSHA256 = "57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf"
    static let projectURL = URL(string: "https://github.com/ExistentialAudio/BlackHole")!

    enum InstallError: LocalizedError {
        case download(String)
        case checksumMismatch
        case authorizationCancelled
        case installerFailed(String)
        case driverDidNotAppear

        var errorDescription: String? {
            switch self {
            case .download(let detail):
                return "Could not download BlackHole: \(detail)"
            case .checksumMismatch:
                return "The downloaded installer did not match its expected checksum, so it was discarded."
            case .authorizationCancelled:
                return "Installation needs your administrator password."
            case .installerFailed(let detail):
                return "The BlackHole installer failed: \(detail)"
            case .driverDidNotAppear:
                return "BlackHole installed but has not appeared yet. Restarting your Mac usually resolves it."
            }
        }
    }

    /// Shown when no BlackHole device is present. Returns true once a device exists.
    @MainActor
    static func runFirstLaunchFlow(detect: @escaping () -> Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "AudioDelay needs one audio driver"
        alert.informativeText = """
            macOS gives apps no way to capture system audio on their own, so AudioDelay uses \
            BlackHole, a free open-source driver by Existential Audio.

            AudioDelay can download and install it for you. It is a 100 KB download and macOS \
            will ask for your administrator password, because audio drivers install system-wide.
            """
        alert.addButton(withTitle: "Install BlackHole")
        alert.addButton(withTitle: "Install Manually")
        alert.addButton(withTitle: "Quit")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            break
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(projectURL)
            return false
        default:
            return false
        }

        do {
            let pkg = try downloadInstaller()
            defer { try? FileManager.default.removeItem(at: pkg.deletingLastPathComponent()) }
            try runInstaller(at: pkg)
        } catch {
            return reportFailure(error)
        }

        // coreaudiod is restarted by BlackHole's own postinstall script, so the device
        // takes a moment to show up.
        guard waitForDriver(detect: detect) else {
            return reportFailure(InstallError.driverDidNotAppear)
        }

        let done = NSAlert()
        done.messageText = "BlackHole installed"
        done.informativeText = "AudioDelay is ready. It lives in the menu bar."
        done.addButton(withTitle: "OK")
        done.runModal()
        return true
    }

    private static func downloadInstaller() throws -> URL {
        var payload: Data?
        var failure: String?
        let done = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: downloadURL) { data, response, error in
            defer { done.signal() }
            if let error {
                failure = error.localizedDescription
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failure = "server returned \(http.statusCode)"
                return
            }
            payload = data
        }
        task.resume()

        if done.wait(timeout: .now() + 120) == .timedOut {
            task.cancel()
            throw InstallError.download("the download timed out")
        }
        if let failure { throw InstallError.download(failure) }
        guard let payload, !payload.isEmpty else {
            throw InstallError.download("the download was empty")
        }

        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256 else { throw InstallError.checksumMismatch }

        // A fresh 0700 directory with an unpredictable name narrows the window in
        // which another local process could swap the verified file before the
        // privileged installer reads it.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AudioDelay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = directory.appendingPathComponent("BlackHole-\(version).pkg")
        try payload.write(to: destination, options: .atomic)
        return destination
    }

    private static func runInstaller(at pkg: URL) throws {
        // Installing into /Library/Audio/Plug-Ins/HAL needs root, so this goes through
        // the standard macOS authorization prompt rather than a bundled helper. The
        // path is escaped for the AppleScript literal and then shell-quoted with
        // `quoted form of`, so no character in it (e.g. from a hostile TMPDIR) can
        // reach root's shell as syntax.
        let escapedPath = pkg.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source =
            "do shell script (\"installer -pkg \" & quoted form of \"\(escapedPath)\" & \" -target /\") with administrator privileges"

        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)

        guard let errorInfo else { return }
        let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
        if code == -128 { throw InstallError.authorizationCancelled }
        let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown error"
        throw InstallError.installerFailed(message)
    }

    private static func waitForDriver(detect: () -> Bool, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if detect() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return detect()
    }

    @MainActor
    private static func reportFailure(_ error: Error) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Could not install BlackHole"
        alert.informativeText = """
            \(error.localizedDescription)

            You can install it yourself from the BlackHole project page, then reopen AudioDelay.
            """
        alert.addButton(withTitle: "Open BlackHole Page")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(projectURL)
        }
        return false
    }
}
