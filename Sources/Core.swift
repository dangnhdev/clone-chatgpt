import AppKit
import Foundation
import CryptoKit
import Darwin

struct CloneConfiguration: Codable {
    var sourceApp: String
    var targetApp: String
    var iconPath: String
    var codexHome: String
    var userDataPath: String
    var bundleIdentifier: String = "com.custom.chatgpt"

    static var defaults: CloneConfiguration {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return .init(sourceApp: "/Applications/ChatGPT.app", targetApp: "/Applications/Chat.app",
                     iconPath: home + "/Downloads/chat.icns",
                     codexHome: home + "/.codex-profiles/chat/codex-home",
                     userDataPath: home + "/Library/Application Support/Codex Profiles/chat/user-data")
    }

    var normalized: CloneConfiguration {
        func path(_ value: String) -> String {
            URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        return .init(sourceApp: path(sourceApp), targetApp: path(targetApp), iconPath: path(iconPath),
                     codexHome: path(codexHome), userDataPath: path(userDataPath), bundleIdentifier: bundleIdentifier)
    }
}

struct CloneResult: Codable {
    var targetApp: String
    var trashPath: String?
    var signed: Bool
    var notes: [String]
}

struct CloneFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum CloneEngine {
    private static let fm = FileManager.default

    static func validate(_ configuration: CloneConfiguration) throws {
        for value in [configuration.sourceApp, configuration.targetApp, configuration.iconPath,
                      configuration.codexHome, configuration.userDataPath] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CloneFailure("All paths are required.")
            }
            guard value.hasPrefix("/") || value.hasPrefix("~/") else {
                throw CloneFailure("Use an absolute path or a path starting with ~/ : \(value)")
            }
        }
        let c = configuration.normalized
        guard c.bundleIdentifier.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else {
            throw CloneFailure("Use a bundle ID such as com.custom.chatgpt (letters, numbers, dots and hyphens).")
        }
        let source = URL(fileURLWithPath: c.sourceApp).resolvingSymlinksInPath().path
        let target = URL(fileURLWithPath: c.targetApp).resolvingSymlinksInPath().path
        guard c.sourceApp.hasSuffix(".app"), c.targetApp.hasSuffix(".app") else {
            throw CloneFailure("Source and destination must be .app bundles.")
        }
        guard source != target, !within(source, target), !within(target, source) else {
            throw CloneFailure("Source and destination must be separate, non-nested apps.")
        }
        for path in [c.sourceApp, c.targetApp] {
            if (try? fm.attributesOfItem(atPath: path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                throw CloneFailure("App paths must not be symbolic links: \(path)")
            }
        }
        let plist = try readPlist(c.sourceApp)
        guard plist["CFBundleIdentifier"] as? String != c.bundleIdentifier else {
            throw CloneFailure("Choose a different bundle ID from the original app.")
        }
        guard let executable = plist["CFBundleExecutable"] as? String,
              !executable.contains("/"), fm.isExecutableFile(atPath: c.sourceApp + "/Contents/MacOS/" + executable) else {
            throw CloneFailure("The source app has no valid executable.")
        }
        if fm.fileExists(atPath: c.targetApp) { _ = try readPlist(c.targetApp) }
        guard fm.isReadableFile(atPath: c.iconPath) else { throw CloneFailure("Cannot read icon: \(c.iconPath)") }
        guard ["icns", "png", "jpg", "jpeg", "tiff"].contains(URL(fileURLWithPath: c.iconPath).pathExtension.lowercased()) else {
            throw CloneFailure("Choose an .icns, .png, .jpg or .tiff icon.")
        }
        guard onMain({ NSImage(contentsOfFile: c.iconPath)?.isValid == true }) else {
            throw CloneFailure("The selected icon is not a valid image: \(c.iconPath)")
        }
        guard fm.isWritableFile(atPath: URL(fileURLWithPath: c.targetApp).deletingLastPathComponent().path) else {
            throw CloneFailure("Destination folder is not writable. Choose a writable folder.")
        }
        let dataPaths = [c.codexHome, c.userDataPath].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        guard dataPaths[0] != dataPaths[1], !within(dataPaths[0], dataPaths[1]), !within(dataPaths[1], dataPaths[0]) else {
            throw CloneFailure("CODEX_HOME and desktop data must be separate, non-nested directories.")
        }
        for path in dataPaths {
            guard !within(path, source), !within(path, target), !within(source, path), !within(target, path) else {
                throw CloneFailure("Profile directories must be outside both app bundles and cannot contain them.")
            }
            var directory: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue {
                throw CloneFailure("Profile path is a file, not a directory: \(path)")
            }
        }
        try ensureNotRunning(c.targetApp)
    }

    private static func within(_ path: String, _ directory: String) -> Bool {
        path == directory || path.hasPrefix(directory + "/")
    }

    private static func ensureNotRunning(_ path: String) throws {
        let running = onMain {
            NSWorkspace.shared.runningApplications.contains {
                $0.bundleURL?.resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            }
        }
        if running { throw CloneFailure("Quit \(URL(fileURLWithPath: path).lastPathComponent) before replacing it.") }
    }

    static func clone(_ configuration: CloneConfiguration, progress: @escaping (String) -> Void) throws -> CloneResult {
        try validate(configuration)
        let c = configuration.normalized
        let digest = SHA256.hash(data: Data(c.targetApp.utf8)).map { String(format: "%02x", $0) }.joined()
        let lockDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/clone-chatgpt")
        try fm.createDirectory(at: lockDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(lockDir.appendingPathComponent(digest + ".lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CloneFailure("Cannot create clone lock.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CloneFailure("Another clone is already using this destination.") }
        defer { _ = flock(fd, LOCK_UN) }

        let target = URL(fileURLWithPath: c.targetApp)
        let stagingRoot = target.deletingLastPathComponent().appendingPathComponent(".clone-chatgpt-" + UUID().uuidString)
        let staging = stagingRoot.appendingPathComponent(target.lastPathComponent)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stagingRoot) }
        progress("Copying \(URL(fileURLWithPath: c.sourceApp).lastPathComponent)…")
        try command("/usr/bin/ditto", [c.sourceApp, staging.path])
        // Vendor bundles can contain read-only resources. Only the private copy
        // needs to be writable for metadata cleanup and nested code signing.
        try command("/bin/chmod", ["-R", "u+rwX", staging.path])
        progress("Setting profile locations…")
        var plist = try readPlist(staging.path)
        plist["CFBundleIdentifier"] = c.bundleIdentifier
        let name = target.deletingPathExtension().lastPathComponent
        plist["CFBundleName"] = name
        plist["CFBundleDisplayName"] = name
        guard let originalExecutable = plist["CFBundleExecutable"] as? String else {
            throw CloneFailure("Source executable metadata is missing.")
        }
        plist["CloneChatGPTOriginalExecutable"] = originalExecutable
        plist["CFBundleExecutable"] = "clone-chatgpt-start"
        let entry = staging.appendingPathComponent("Contents/MacOS/clone-chatgpt-start")
        try nativeStarterData.write(to: entry)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
        var env = plist["LSEnvironment"] as? [String: String] ?? [:]
        env["CODEX_HOME"] = c.codexHome
        env["CODEX_ELECTRON_USER_DATA_PATH"] = c.userDataPath
        plist["LSEnvironment"] = env
        try writePlist(plist, app: staging.path)

        progress("Preparing custom icon…")
        try prepareIcon(c.iconPath, app: staging.path)
        progress("Signing and verifying the clone…")
        try command("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", "--preserve-metadata=entitlements,flags,runtime", staging.path])
        try signLocalBundles(staging.path, workDirectory: stagingRoot)
        try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", staging.path])
        let verified = try readPlist(staging.path)["LSEnvironment"] as? [String: String]
        guard verified?["CODEX_HOME"] == c.codexHome, verified?["CODEX_ELECTRON_USER_DATA_PATH"] == c.userDataPath else {
            throw CloneFailure("Profile verification failed.")
        }
        for path in [c.codexHome, c.userDataPath] {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try ensureNotRunning(c.targetApp)
        var trashURL: NSURL?
        if fm.fileExists(atPath: c.targetApp) {
            progress("Moving the existing app to Trash…")
            try fm.trashItem(at: target, resultingItemURL: &trashURL)
        }
        do {
            progress("Installing \(target.lastPathComponent)…")
            try fm.moveItem(at: staging, to: target)
        } catch {
            if let old = trashURL as URL?, !fm.fileExists(atPath: c.targetApp) { try? fm.moveItem(at: old, to: target) }
            throw CloneFailure("Could not install the clone: \(error.localizedDescription). Previous app: \(trashURL?.path ?? "none").")
        }
        let register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        var notes = ["Open the clone using Finder, Dock or open; its native entry point supplies the fixed profile arguments.",
                     "The clone is signed locally (ad-hoc), with its own app identity. OpenAI-only entitlements are removed; re-clone after updating the source."]
        if fm.isExecutableFile(atPath: register) {
            do { try command(register, ["-f", c.targetApp]) }
            catch { notes.append("Launch Services registration failed: \(error.localizedDescription)") }
        }
        progress("Clone ready.")
        return CloneResult(targetApp: c.targetApp, trashPath: trashURL?.path, signed: true, notes: notes)
    }

    private static func prepareIcon(_ path: String, app: String) throws {
        let changed = onMain {
            guard let image = NSImage(contentsOfFile: path) else { return false }
            return NSWorkspace.shared.setIcon(image, forFile: app, options: [])
        }
        guard changed else { throw CloneFailure("macOS could not set the selected icon.") }

        // setIcon adds FinderInfo/ResourceFork metadata, which codesign rejects.
        // Keep the selected artwork as a bundle icon, then clear that metadata
        // before signing. This also gives the running app the selected icon.
        let iconURL = URL(fileURLWithPath: app).appendingPathComponent("Contents/Resources/clone-chatgpt.icns")
        try fm.createDirectory(at: iconURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if URL(fileURLWithPath: path).pathExtension.lowercased() == "icns" {
            try Data(contentsOf: URL(fileURLWithPath: path)).write(to: iconURL, options: .atomic)
        } else {
            let iconset = URL(fileURLWithPath: app).deletingLastPathComponent().appendingPathComponent("custom.iconset")
            try fm.createDirectory(at: iconset, withIntermediateDirectories: false)
            let sizes: [(Int, String)] = [(16,"icon_16x16.png"),(32,"icon_16x16@2x.png"),
                (32,"icon_32x32.png"),(64,"icon_32x32@2x.png"),(128,"icon_128x128.png"),
                (256,"icon_128x128@2x.png"),(256,"icon_256x256.png"),(512,"icon_256x256@2x.png"),
                (512,"icon_512x512.png"),(1024,"icon_512x512@2x.png")]
            for (size, filename) in sizes {
                let output = iconset.appendingPathComponent(filename).path
                try command("/usr/bin/sips", ["-s", "format", "png", "-z", "\(size)", "\(size)", path, "--out", output])
            }
            try command("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", iconURL.path])
        }
        var plist = try readPlist(app)
        plist["CFBundleIconFile"] = "clone-chatgpt.icns"
        plist.removeValue(forKey: "CFBundleIconName")
        plist.removeValue(forKey: "CFBundleIcons")
        try writePlist(plist, app: app)
        let finderIcon = URL(fileURLWithPath: app).appendingPathComponent("Icon\r")
        if fm.fileExists(atPath: finderIcon.path) { try fm.removeItem(at: finderIcon) }
        try command("/usr/bin/xattr", ["-dr", "com.apple.FinderInfo", app])
        try command("/usr/bin/xattr", ["-dr", "com.apple.ResourceFork", app])
    }

    private static func signLocalBundles(_ app: String, workDirectory: URL) throws {
        let root = URL(fileURLWithPath: app)
        var bundles = [root]
        if let executable = try readPlist(app)["CloneChatGPTOriginalExecutable"] as? String {
            bundles.append(root.appendingPathComponent("Contents/MacOS/" + executable))
        }
        if let entries = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in entries {
                guard ["app", "xpc", "appex", "plugin", "framework"].contains(url.pathExtension),
                      (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
                bundles.append(url)
            }
        }
        for bundle in bundles.sorted(by: { $0.path.count > $1.path.count }) {
            try signLocalApp(bundle.path, workDirectory: workDirectory)
        }
    }

    private static func signLocalApp(_ app: String, workDirectory: URL) throws {
        // Apple team identities, APNs and shared keychain/application groups
        // require OpenAI's signing identity. An ad-hoc clone cannot claim them;
        // keeping them causes launchd/AMFI to reject an otherwise valid seal.
        let output = try command("/usr/bin/codesign", ["-d", "--entitlements", ":-", app])
        var entitlements: [String: Any] = [:]
        if let start = output.range(of: "<?xml"), let end = output.range(of: "</plist>", range: start.lowerBound..<output.endIndex) {
            let data = Data(output[start.lowerBound..<end.upperBound].utf8)
            entitlements = (try PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
        }
        let restricted: Set<String> = ["com.apple.application-identifier", "application-identifier",
            "com.apple.security.application-groups", "keychain-access-groups"]
        entitlements = entitlements.filter { !restricted.contains($0.key) && !$0.key.hasPrefix("com.apple.developer.") }
        // Ad-hoc code has no Apple Team ID. Electron apps and their helpers
        // must be able to load the locally signed framework without comparing
        // it to OpenAI's former team identity. Keep other runtime protections.
        var isDirectory: ObjCBool = false
        _ = fm.fileExists(atPath: app, isDirectory: &isDirectory)
        if app.hasSuffix(".app") || !isDirectory.boolValue {
            entitlements["com.apple.security.cs.disable-library-validation"] = true
        }
        let file = workDirectory.appendingPathComponent("local-entitlements.plist")
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: file)
        try command("/usr/bin/codesign", ["--force", "--sign", "-", "--preserve-metadata=flags,runtime", "--entitlements", file.path, app])
    }

    static func readPlist(_ app: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: app).appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CloneFailure("Invalid Info.plist in \(app)")
        }
        return plist
    }

    private static func writePlist(_ plist: [String: Any], app: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: app).appendingPathComponent("Contents/Info.plist"), options: .atomic)
    }

    private static func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    @discardableResult static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        // A file avoids pipe-buffer deadlocks while signing large nested apps.
        let log = fm.temporaryDirectory.appendingPathComponent("clone-chatgpt-process-" + UUID().uuidString)
        fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close(); try? fm.removeItem(at: log) }
        task.standardOutput = handle
        task.standardError = handle
        try task.run()
        task.waitUntilExit()
        let output = String(data: try Data(contentsOf: log), encoding: .utf8) ?? ""
        guard task.terminationStatus == 0 else {
            throw CloneFailure("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(task.terminationStatus)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }
}
