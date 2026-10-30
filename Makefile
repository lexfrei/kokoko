# Kokoko build shortcuts. Checks and smoke runs need only Command Line Tools;
# .app/.ipa builds need Xcode (xcodebuild).

# xcode-select still points at Command Line Tools; force Xcode here.
DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

.PHONY: check e2e probe vep run-mac generate app ios

check:
	swift run KokokoCoreChecks

e2e:
	swift run kokoko-e2e

probe:
	swift run kokoko-probe

vep:
	swift run vep

run-mac:
	swift run kokoko-mac

generate:
	xcodegen generate

# macOS .app without Xcode: SPM release binary + Info.plist + ad-hoc sign.
bundle:
	swift build -c release --target kokoko-mac
	mkdir -p dist/kokoko.app/Contents/MacOS
	cp .build/release/kokoko-mac dist/kokoko.app/Contents/MacOS/kokoko
	cp Resources/Info.plist dist/kokoko.app/Contents/Info.plist
	codesign --force --sign - dist/kokoko.app
	@echo "dist/kokoko.app"

app: generate
	xcodebuild -project kokoko.xcodeproj -scheme kokoko -destination 'platform=macOS' -configuration Debug build

ios: generate
	xcodebuild -project kokoko.xcodeproj -scheme kokoko -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build
