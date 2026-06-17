APP_NAME ?= Open Speech ASR
EXECUTABLE_NAME ?= OpenSpeechASR
BUNDLE_ID ?= com.openspeech.asr
MARKETING_VERSION ?= 1.0
BUILD_VERSION ?= 1.0.1
BUILD_DIR = build
SPM_CONFIG ?= release
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CODESIGN_IDENTITY ?= -
ENTITLEMENTS ?= FreeFlow.entitlements
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources
APP_EXECUTABLE = $(MACOS_DIR)/$(EXECUTABLE_NAME)
BACKEND_SOURCE ?= backend
BACKEND_RUNTIME_SOURCE ?= ../openspeech-dev/backend
BUNDLED_BACKEND = $(RESOURCES)/backend
QWEN3_ASR_MODEL_SOURCE ?= /Users/paco/Documents/LLM-Models/Qwen3-ASR-1.7B-4bit
QWEN3_ASR_MODEL_BUNDLE_NAME = qwen3-asr-1.7b-4bit
QWEN3_ASR_MODEL_BUNDLE = $(RESOURCES)/$(QWEN3_ASR_MODEL_BUNDLE_NAME)
SWIFTPM_BINARY = .build/$(SPM_CONFIG)/$(EXECUTABLE_NAME)
SWIFTPM_METALLIB = .build/$(SPM_CONFIG)/mlx.metallib
SPEECH_SWIFT_METALLIB_SCRIPT = scripts/build_mlx_metallib.sh

ICON_SOURCE = Resources/AppIcon-Source.png
ICON_ICNS = Resources/AppIcon.icns

.PHONY: all clean run icon swift-build shader bundle-model bundle-backend codesign-app dmg codesign-dmg distribution-check notarize reset-local-state stop-running

all: stop-running swift-build shader $(APP_EXECUTABLE) bundle-model bundle-backend codesign-app

stop-running:
	@./scripts/stop_running_instances.sh

swift-build:
	swift build -c $(SPM_CONFIG) --disable-sandbox

shader: swift-build
	@test -x "$(SPEECH_SWIFT_METALLIB_SCRIPT)" || (echo "Missing speech-swift metallib script. Run swift build first." && exit 1)
	BUILD_DIR="$$(pwd)/.build" "$(SPEECH_SWIFT_METALLIB_SCRIPT)" $(SPM_CONFIG)

$(APP_EXECUTABLE): Info.plist $(ICON_ICNS) swift-build shader
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES)"
	@test -f "$(SWIFTPM_BINARY)" || (echo "Missing SwiftPM binary: $(SWIFTPM_BINARY)" && exit 1)
	@cp "$(SWIFTPM_BINARY)" "$(APP_EXECUTABLE)"
	@if [ -f "$(SWIFTPM_METALLIB)" ]; then cp "$(SWIFTPM_METALLIB)" "$(MACOS_DIR)/mlx.metallib"; fi
	@cp Info.plist "$(CONTENTS)/"
	@plutil -replace CFBundleName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleDisplayName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleExecutable -string "$(EXECUTABLE_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleShortVersionString -string "$(MARKETING_VERSION)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleVersion -string "$(BUILD_VERSION)" "$(CONTENTS)/Info.plist"
	@plutil -replace LSMinimumSystemVersion -string "15.0" "$(CONTENTS)/Info.plist"
	@cp $(ICON_ICNS) "$(RESOURCES)/AppIcon.icns"
	@plutil -replace NSMicrophoneUsageDescription -string "$(APP_NAME) needs microphone access to transcribe your speech." "$(CONTENTS)/Info.plist"
	@plutil -replace NSSpeechRecognitionUsageDescription -string "$(APP_NAME) needs speech recognition to convert your voice to text." "$(CONTENTS)/Info.plist"
	@plutil -replace NSAccessibilityUsageDescription -string "$(APP_NAME) needs accessibility access to detect the text cursor position and paste transcribed text." "$(CONTENTS)/Info.plist"
	@echo "Built $(APP_BUNDLE)"

bundle-model:
	@test -d "$(QWEN3_ASR_MODEL_SOURCE)" || (echo "Missing Qwen3-ASR model dir: $(QWEN3_ASR_MODEL_SOURCE)" && exit 1)
	@test -f "$(QWEN3_ASR_MODEL_SOURCE)/model.safetensors" || (echo "Missing Qwen3-ASR model.safetensors" && exit 1)
	@test -f "$(QWEN3_ASR_MODEL_SOURCE)/vocab.json" || (echo "Missing Qwen3-ASR vocab.json" && exit 1)
	@test -f "$(QWEN3_ASR_MODEL_SOURCE)/merges.txt" || (echo "Missing Qwen3-ASR merges.txt" && exit 1)
	@rm -rf "$(QWEN3_ASR_MODEL_BUNDLE)"
	@mkdir -p "$(QWEN3_ASR_MODEL_BUNDLE)"
	@ditto --norsrc --noextattr "$(QWEN3_ASR_MODEL_SOURCE)" "$(QWEN3_ASR_MODEL_BUNDLE)"
	@rm -rf "$(QWEN3_ASR_MODEL_BUNDLE)/._____temp"
	@echo "Bundled Qwen3-ASR model into $(QWEN3_ASR_MODEL_BUNDLE)"

bundle-backend:
	@if [ ! -d "$(BACKEND_SOURCE)" ]; then \
		echo "No local Gemma backend source at $(BACKEND_SOURCE); skipping bundled Python backend"; \
		exit 0; \
	fi
	@test -f "$(BACKEND_SOURCE)/inference_server.py" || (echo "Missing $(BACKEND_SOURCE)/inference_server.py" && exit 1)
	@test -f "$(BACKEND_SOURCE)/config.yaml" || (echo "Missing $(BACKEND_SOURCE)/config.yaml" && exit 1)
	@test -d "$(BACKEND_RUNTIME_SOURCE)/python" || (echo "Missing $(BACKEND_RUNTIME_SOURCE)/python" && exit 1)
	@rm -rf "$(BUNDLED_BACKEND)"
	@mkdir -p "$(BUNDLED_BACKEND)/models"
	@cp "$(BACKEND_SOURCE)/config.yaml" "$(BUNDLED_BACKEND)/"
	@cp "$(BACKEND_SOURCE)/inference_server.py" "$(BUNDLED_BACKEND)/"
	@if [ -d "$(BACKEND_RUNTIME_SOURCE)/models/gemma-e4b-q4" ]; then \
		ditto "$(BACKEND_RUNTIME_SOURCE)/models/gemma-e4b-q4" "$(BUNDLED_BACKEND)/models/gemma-e4b-q4"; \
	fi
	@if [ -d "$(BACKEND_RUNTIME_SOURCE)/models/sensevoice" ]; then \
		ditto "$(BACKEND_RUNTIME_SOURCE)/models/sensevoice" "$(BUNDLED_BACKEND)/models/sensevoice"; \
	fi
	@ditto "$(BACKEND_RUNTIME_SOURCE)/python" "$(BUNDLED_BACKEND)/python"
	@ln -sf "python/standalone/bin/python3.13" "$(BUNDLED_BACKEND)/$(APP_NAME)"
	@find "$(BUNDLED_BACKEND)/python/standalone" -type d \( -name '__pycache__' -o -name 'tests' -o -name 'test' \) -prune -exec rm -rf {} +
	@find "$(BUNDLED_BACKEND)/python/standalone" -type f \( -name '*.pyc' -o -name '*.pyo' -o -name '*.a' \) -delete
	@rm -rf \
		"$(BUNDLED_BACKEND)/python/standalone/bin/idle3.13" \
		"$(BUNDLED_BACKEND)/python/standalone/bin/idle3" \
		"$(BUNDLED_BACKEND)/python/standalone/bin/pydoc3.13" \
		"$(BUNDLED_BACKEND)/python/standalone/bin/python3.13-config" \
		"$(BUNDLED_BACKEND)/python/standalone/bin/pip" \
		"$(BUNDLED_BACKEND)/python/standalone/bin/pip3" \
		"$(BUNDLED_BACKEND)/python/standalone/bin/pip3.13" \
		"$(BUNDLED_BACKEND)/python/standalone/lib/libtcl9.0.dylib" \
		"$(BUNDLED_BACKEND)/python/standalone/lib/libtcl9tk9.0.dylib" \
		"$(BUNDLED_BACKEND)/python/standalone/lib/tcl9" \
		"$(BUNDLED_BACKEND)/python/standalone/lib/tcl9.0" \
		"$(BUNDLED_BACKEND)/python/standalone/lib/tk9.0" \
		"$(BUNDLED_BACKEND)/python/standalone/lib/thread3.0.4" \
		"$(BUNDLED_BACKEND)/python/standalone/lib/itcl4.3.5" \
		"$(BUNDLED_BACKEND)/python/standalone/lib/python3.13/idlelib" \
		"$(BUNDLED_BACKEND)/python/standalone/lib/python3.13/tkinter" \
		"$(BUNDLED_BACKEND)/python/standalone/lib/python3.13/turtledemo" \
		"$(BUNDLED_BACKEND)/python/standalone/lib/python3.13/lib-dynload/_tkinter.cpython-313-darwin.so"
	@find "$(BUNDLED_BACKEND)/python/standalone" -type l -exec sh -c 'for link do [ -e "$$link" ] || rm -f "$$link"; done' sh {} +
	@echo "Bundled Gemma correction backend into $(BUNDLED_BACKEND)"

codesign-app: bundle-model bundle-backend
	@if [ "$(CODESIGN_IDENTITY)" = "-" ]; then \
		codesign --force --deep -s - "$(APP_BUNDLE)"; \
		echo "Ad-hoc signed $(APP_BUNDLE)"; \
	else \
		codesign --force --deep --timestamp --options runtime --entitlements "$(ENTITLEMENTS)" \
			--sign "$(CODESIGN_IDENTITY)" "$(APP_BUNDLE)"; \
		echo "Developer ID signed $(APP_BUNDLE)"; \
	fi

icon: $(ICON_ICNS)

$(ICON_ICNS): $(ICON_SOURCE)
	@mkdir -p $(BUILD_DIR)/AppIcon.iconset
	@sips -z 16 16 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16.png > /dev/null
	@sips -z 32 32 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16@2x.png > /dev/null
	@sips -z 32 32 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32.png > /dev/null
	@sips -z 64 64 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32@2x.png > /dev/null
	@sips -z 128 128 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128.png > /dev/null
	@sips -z 256 256 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128@2x.png > /dev/null
	@sips -z 256 256 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256.png > /dev/null
	@sips -z 512 512 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256@2x.png > /dev/null
	@sips -z 512 512 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512.png > /dev/null
	@sips -z 1024 1024 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512@2x.png > /dev/null
	@iconutil -c icns -o $@ $(BUILD_DIR)/AppIcon.iconset
	@rm -rf $(BUILD_DIR)/AppIcon.iconset
	@echo "Generated $@"

dmg: reset-local-state all
	@rm -f "$(BUILD_DIR)/$(APP_NAME).dmg"
	@rm -rf $(BUILD_DIR)/dmg-staging
	@mkdir -p $(BUILD_DIR)/dmg-staging
	@cp -R "$(APP_BUNDLE)" $(BUILD_DIR)/dmg-staging/
	@osascript -e 'tell application "Finder" to make alias file to POSIX file "/Applications" at POSIX file "'"$$(cd $(BUILD_DIR)/dmg-staging && pwd)"'"'
	@ALIAS=$$(find $(BUILD_DIR)/dmg-staging -maxdepth 1 -not -name '*.app' -not -name '.DS_Store' -type f | head -1) && mv "$$ALIAS" "$(BUILD_DIR)/dmg-staging/Applications"
	@if command -v fileicon >/dev/null 2>&1; then \
		fileicon set "$(BUILD_DIR)/dmg-staging/Applications" /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns; \
	else \
		echo "fileicon not found; skipping Applications alias icon"; \
	fi
	@echo "Creating DMG..."
	@if command -v create-dmg >/dev/null 2>&1; then \
		create-dmg \
			--volname "$(APP_NAME)" \
			--volicon "$(ICON_ICNS)" \
			--window-pos 200 120 \
			--window-size 660 400 \
			--icon "$(APP_NAME).app" 180 170 \
			--hide-extension "$(APP_NAME).app" \
			--icon "Applications" 480 170 \
			--no-internet-enable \
			"$(BUILD_DIR)/$(APP_NAME).dmg" \
			"$(BUILD_DIR)/dmg-staging"; \
	else \
		echo "create-dmg not found; using hdiutil fallback"; \
		hdiutil create -volname "$(APP_NAME)" -srcfolder "$(BUILD_DIR)/dmg-staging" -ov -format UDZO "$(BUILD_DIR)/$(APP_NAME).dmg"; \
	fi
	@rm -rf $(BUILD_DIR)/dmg-staging
	@echo "Created $(BUILD_DIR)/$(APP_NAME).dmg"

codesign-dmg: dmg
	@test "$(CODESIGN_IDENTITY)" != "-" || (echo "Set CODESIGN_IDENTITY to a Developer ID Application certificate before signing the DMG." && exit 1)
	codesign --force --timestamp --sign "$(CODESIGN_IDENTITY)" "$(BUILD_DIR)/$(APP_NAME).dmg"

distribution-check:
	@test "$(CODESIGN_IDENTITY)" != "-" || (echo "Set CODESIGN_IDENTITY to a Developer ID Application certificate." && exit 1)
	@security find-identity -p codesigning -v | grep -F "$(CODESIGN_IDENTITY)" >/dev/null || \
		(echo "Could not find signing identity: $(CODESIGN_IDENTITY)" && exit 1)
	@codesign -dvvv "$(APP_BUNDLE)" 2>&1 | grep -q "Authority=Developer ID Application" || \
		(echo "$(APP_BUNDLE) is not signed with Developer ID Application. Run make all CODESIGN_IDENTITY=\"$(CODESIGN_IDENTITY)\" first." && exit 1)
	@codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"
	@spctl -a -vv --type execute "$(APP_BUNDLE)"

notarize: codesign-dmg
	@test -n "$(NOTARIZE_PROFILE)" || (echo "Set NOTARIZE_PROFILE to a stored notarytool keychain profile." && exit 1)
	xcrun notarytool submit "$(BUILD_DIR)/$(APP_NAME).dmg" \
		--keychain-profile "$(NOTARIZE_PROFILE)" --wait
	xcrun stapler staple "$(BUILD_DIR)/$(APP_NAME).dmg"

reset-local-state:
	@./scripts/reset_local_state.sh

clean:
	rm -rf $(BUILD_DIR) .build

run: all
	open "$(APP_BUNDLE)"
