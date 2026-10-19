import AppKit
import Foundation

let usage = """
clone-chatgpt — create a ChatGPT/Codex clone with a fixed profile and custom icon

Usage:
  clone-chatgpt gui                       Open the native GUI (also the default)
  clone-chatgpt clone [options]           Create or replace the clone
  clone-chatgpt clone --dry-run [options] Validate and preview without changes
  clone-chatgpt doctor [options]          Check source, paths and signing tools
  clone-chatgpt --help

Options (apply to GUI, clone and doctor):
  --source PATH       Default: /Applications/ChatGPT.app
  --target PATH       Default: /Applications/Chat.app
  --icon PATH         Default: ~/Downloads/chat.icns
  --codex-home PATH   Default: ~/.codex-profiles/chat/codex-home
  --user-data PATH    Default: ~/Library/Application Support/Codex Profiles/chat/user-data
  --bundle-id ID      Default: com.custom.chatgpt (must differ from the source)
  --json             Print a JSON success/error envelope (CLI only)
  --dry-run          Validate and preview; do not copy, trash or modify files

An existing target goes to macOS Trash after the replacement passes validation.
Quit the target before replacing it. The original source and profile contents
are preserved. Open the result from Finder/Dock to apply its profile settings.
"""

func output(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
}

var config = CloneConfiguration.defaults
let args = Array(CommandLine.arguments.dropFirst())
var action = "gui", json = args.contains("--json"), dryRun = false, index = 0, foundAction = false
do {
    while index < args.count {
        let arg = args[index]
        if arg == "--help" || arg == "-h" { print(usage); exit(0) }
        if ["gui", "clone", "doctor"].contains(arg), !foundAction { action = arg; foundAction = true }
        else if arg == "--json" { json = true }
        else if arg == "--dry-run" { dryRun = true }
        else if ["--source", "--target", "--icon", "--codex-home", "--user-data", "--bundle-id"].contains(arg) {
            index += 1
            guard index < args.count, !args[index].hasPrefix("--") else { throw CloneFailure("Missing value for \(arg)") }
            switch arg {
            case "--source": config.sourceApp = args[index]
            case "--target": config.targetApp = args[index]
            case "--icon": config.iconPath = args[index]
            case "--codex-home": config.codexHome = args[index]
            case "--bundle-id": config.bundleIdentifier = args[index]
            default: config.userDataPath = args[index]
            }
        } else if arg.hasPrefix("-psn_") { /* Finder legacy launch argument */ }
        else { throw CloneFailure("Unknown argument: \(arg). Use --help.") }
        index += 1
    }
    if action == "gui", json || dryRun { throw CloneFailure("--json and --dry-run require clone or doctor.") }
    if action == "gui" { runGUI(initial: config); exit(0) }
    try CloneEngine.validate(config)
    if action == "doctor" || dryRun {
        let normalized = config.normalized
        let data = try JSONEncoder().encode(normalized)
        let configuration = try JSONSerialization.jsonObject(with: data)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign") else { throw CloneFailure("codesign is unavailable.") }
        let exists = FileManager.default.fileExists(atPath: normalized.targetApp)
        let payload: [String: Any] = ["configuration": configuration, "targetExists": exists,
                                      "willTrashExistingTarget": exists, "authRequired": false,
                                      "mode": "local", "dryRun": dryRun]
        if json { output(["ok": true, "command": action, "data": payload]) }
        else {
            print("Paths and source app are valid. No changes made.")
            print("Source: \(normalized.sourceApp)\nTarget: \(normalized.targetApp)\nIcon: \(normalized.iconPath)")
            print("CODEX_HOME: \(normalized.codexHome)\nDesktop data: \(normalized.userDataPath)")
            print(exists ? "Existing target will be moved to Trash." : "No existing target to replace.")
        }
        exit(0)
    }
    let result = try CloneEngine.clone(config) { message in
        if !json { FileHandle.standardError.write(Data((message + "\n").utf8)) }
    }
    if json {
        let data = try JSONEncoder().encode(result)
        output(["ok": true, "command": action, "data": try JSONSerialization.jsonObject(with: data)])
    } else {
        print("Created: \(result.targetApp)")
        if let old = result.trashPath { print("Previous app in Trash: \(old)") }
        for note in result.notes { print(note) }
    }
} catch {
    if json { output(["ok": false, "error": ["message": error.localizedDescription]]) }
    else { FileHandle.standardError.write(Data(("Error: " + error.localizedDescription + "\n").utf8)) }
    exit(1)
}
