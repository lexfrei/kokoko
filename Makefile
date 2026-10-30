# Kokoko build shortcuts. Checks and smoke runs need only Command Line Tools;
# .app/.ipa builds need Xcode (xcodebuild).

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

app: generate
	xcodebuild -project kokoko.xcodeproj -scheme kokoko -destination 'platform=macOS' -configuration Debug build

ios: generate
	xcodebuild -project kokoko.xcodeproj -scheme kokoko -destination 'generic/platform=iOS' -configuration Debug build
