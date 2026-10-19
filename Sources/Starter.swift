import Foundation
import Darwin

// A native entry point, not a shell script. Chromium's singleton check happens
// before Electron's JavaScript can apply CODEX_ELECTRON_USER_DATA_PATH.
let app = Bundle.main.bundleURL
do {
    let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let env = plist["LSEnvironment"] as? [String: String],
          let userData = env["CODEX_ELECTRON_USER_DATA_PATH"],
          let original = plist["CloneChatGPTOriginalExecutable"] as? String,
          !original.contains("/"), !original.isEmpty else {
        throw NSError(domain: "clone-chatgpt", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing startup profile configuration"])
    }
    for (key, value) in env { setenv(key, value, 1) }
    let executable = app.appendingPathComponent("Contents/MacOS/" + original).path
    let arguments = [executable, "--user-data-dir=" + userData] + Array(CommandLine.arguments.dropFirst())
    let allocated = arguments.map { strdup($0) }
    defer { for pointer in allocated { free(pointer) } }
    var argv = allocated + [nil]
    let result = argv.withUnsafeMutableBufferPointer { execv(executable, $0.baseAddress!) }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not start original executable (\(result))"])
} catch {
    FileHandle.standardError.write(Data(("clone-chatgpt: " + error.localizedDescription + "\n").utf8))
    exit(1)
}
