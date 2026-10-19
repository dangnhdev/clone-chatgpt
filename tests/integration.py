"""Exercise real copy, Trash, icon, plist, signing and safe preflight failures."""
import hashlib
import json
import os
import pathlib
import plistlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = ROOT / "build/clone-chatgpt"
ICON = pathlib.Path.home() / "Downloads/chat.icns"


def run(*args, ok=True):
    result = subprocess.run([str(BIN), *args], text=True, capture_output=True)
    payload = json.loads(result.stdout)
    assert (result.returncode == 0) == ok, (result.stdout, result.stderr)
    assert payload["ok"] == ok, payload
    return payload


with tempfile.TemporaryDirectory(prefix="clone-chatgpt-test-") as directory:
    root = pathlib.Path(directory)
    source = root / "Original App.app"
    target = root / "Clone Test.app"
    macos = source / "Contents/MacOS"
    macos.mkdir(parents=True)
    c = root / "fixture.c"
    c.write_text('#include <stdio.h>\n#include <stdlib.h>\nint main(int argc, char **argv) { printf("%s\\n%s\\n%s\\n", argc > 1 ? argv[1] : "", getenv("CODEX_HOME") ?: "", getenv("CODEX_ELECTRON_USER_DATA_PATH") ?: ""); return 0; }\n')
    subprocess.run(["xcrun", "clang", str(c), "-o", str(macos / "fixture")], check=True)
    plist_path = source / "Contents/Info.plist"
    initial = {"CFBundleIdentifier": "local.clone-chatgpt.test", "CFBundleExecutable": "fixture",
               "CFBundlePackageType": "APPL", "CFBundleName": "Clone Test",
               "CFBundleIconName": "OldIcon", "LSEnvironment": {"PRESERVE_ME": "yes"}}
    plist_path.write_bytes(plistlib.dumps(initial))
    (source / "Contents/Resources").mkdir()
    readonly = source / "Contents/Resources/readonly-resource.json"
    readonly.write_text('{}')
    readonly.chmod(0o444)
    entitlements = root / "original-entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.cs.allow-jit": True,
        "com.apple.developer.team-identifier": "EXAMPLE123", "com.apple.developer.aps-environment": "production",
        "com.apple.security.application-groups": ["EXAMPLE123.shared"], "keychain-access-groups": ["EXAMPLE123.*"]}))
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(source)], check=True)
    source_hash = hashlib.sha256(plist_path.read_bytes()).hexdigest()
    codex = root / "codex home"
    userdata = root / "desktop data"
    codex.mkdir()
    (codex / "keep.txt").write_text("existing profile")
    options = ["--source", str(source), "--target", str(target), "--icon", str(ICON),
               "--codex-home", str(codex), "--user-data", str(userdata)]
    preview = run("clone", "--dry-run", "--json", *options)
    assert preview["data"]["dryRun"]
    assert not target.exists() and not userdata.exists()
    result = run("clone", "--json", *options)["data"]
    assert result["signed"] and "trashPath" not in result
    plist = plistlib.loads((target / "Contents/Info.plist").read_bytes())
    assert plist["LSEnvironment"] == {"PRESERVE_ME": "yes", "CODEX_HOME": str(codex),
                                       "CODEX_ELECTRON_USER_DATA_PATH": str(userdata)}
    assert "CFBundleIconName" not in plist
    assert plist["CFBundleIdentifier"] == "com.custom.chatgpt"
    assert plist["CFBundleName"] == "Clone Test"
    assert plist["CFBundleExecutable"] == "clone-chatgpt-start"
    assert plist["CloneChatGPTOriginalExecutable"] == "fixture"
    starter_run = subprocess.run([str(target / "Contents/MacOS/clone-chatgpt-start")], capture_output=True, text=True)
    assert starter_run.returncode == 0, starter_run.stderr
    assert starter_run.stdout.splitlines() == ['--user-data-dir=' + str(userdata), str(codex), str(userdata)]
    assert plist["CFBundleIconFile"] == "clone-chatgpt.icns"
    assert (target / "Contents/Resources/clone-chatgpt.icns").read_bytes() == ICON.read_bytes()
    assert not (target / "Icon\r").exists()
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(target)], check=True)
    seal = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(target / "Contents/MacOS/fixture")], capture_output=True, text=True, check=True)
    sealed = plistlib.loads(seal.stdout.encode())
    assert sealed == {"com.apple.security.cs.allow-jit": True,
                      "com.apple.security.cs.disable-library-validation": True}, sealed
    assert hashlib.sha256(plist_path.read_bytes()).hexdigest() == source_hash
    assert readonly.stat().st_mode & 0o777 == 0o444
    assert (codex / "keep.txt").read_text() == "existing profile"
    assert userdata.is_dir()
    # A marker proves the previous app was actually moved, not deleted/overwritten.
    (target / "old-marker.txt").write_text("old clone")
    replacement = run("clone", "--json", *options)["data"]
    trashed = pathlib.Path(replacement["trashPath"])
    assert trashed.is_dir() and (trashed / "old-marker.txt").read_text() == "old clone"
    assert not (target / "old-marker.txt").exists()
    assert not list(root.glob(".clone-chatgpt-*"))
    # Reject aliasing the original and an invalid image before touching the app.
    run("clone", "--json", *options, "--target", str(source), ok=False)
    run("clone", "--json", *options, "--bundle-id", "bad/id", ok=False)
    broken = root / "broken.png"
    broken.write_text("not an image")
    target_hash = hashlib.sha256((target / "Contents/Info.plist").read_bytes()).hexdigest()
    run("clone", "--json", *options, "--icon", str(broken), ok=False)
    assert hashlib.sha256((target / "Contents/Info.plist").read_bytes()).hexdigest() == target_hash
    # Exercise the GUI's non-ICNS icon path.
    png = root / "selected.png"
    subprocess.run(["/usr/bin/sips", "-s", "format", "png", str(ICON), "--out", str(png)], check=True, capture_output=True)
    png_clone = root / "PNG Clone.app"
    run("clone", "--json", *options, "--target", str(png_clone), "--icon", str(png), "--bundle-id", "com.custom.png-test")
    assert plistlib.loads((png_clone / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"] == "com.custom.png-test"
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(png_clone)], check=True)
    assert (png_clone / "Contents/Resources/clone-chatgpt.icns").stat().st_size > 0

print("PASS: dry-run, copy, custom icon, plist, deep signing, Trash replacement, source/profile preservation, failure preflight, PNG conversion")
