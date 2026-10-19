SWIFTC := xcrun swiftc
BIN := build/clone-chatgpt
SOURCES := Sources/Core.swift Sources/GUI.swift Sources/main.swift build/StarterPayload.swift
APP := build/Clone ChatGPT.app

.PHONY: all app install clean test
all: $(BIN) app

build/native-starter: Sources/Starter.swift
	mkdir -p build
	$(SWIFTC) -swift-version 5 -O Sources/Starter.swift -o "$@"

build/StarterPayload.swift: build/native-starter
	python3 -c 'import base64,pathlib; b=base64.b64encode(pathlib.Path("build/native-starter").read_bytes()).decode(); pathlib.Path("build/StarterPayload.swift").write_text("import Foundation\nlet nativeStarterData = Data(base64Encoded: \"" + b + "\")!\n")'

$(BIN): $(SOURCES)
	mkdir -p build
	$(SWIFTC) -swift-version 5 -O -framework AppKit $(SOURCES) -o "$(BIN)"

app: $(BIN)
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$(BIN)" "$(APP)/Contents/MacOS/clone-chatgpt"
	/usr/libexec/PlistBuddy -c 'Clear dict' "$(APP)/Contents/Info.plist" >/dev/null
	/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string local.clone-chatgpt.gui' "$(APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c 'Add :CFBundleName string Clone ChatGPT' "$(APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string clone-chatgpt' "$(APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$(APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 1.0' "$(APP)/Contents/Info.plist"
	/usr/bin/codesign --force --sign - "$(APP)"

install: all
	mkdir -p "$(HOME)/.local/bin"
	install -m 755 "$(BIN)" "$(HOME)/.local/bin/clone-chatgpt"

test: $(BIN)
	python3 tests/integration.py

clean:
	rm -rf build
