CONFIG ?= release
BUNDLE_ID := app.moomux.Moomux
APP := .build/Moomux.app
# Distribution signs with a Developer ID instead of the ad-hoc identity `app`
# uses — that's the only cert that can be notarized. Falls back to "-" (ad-hoc)
# when no Developer ID cert is installed, so `dist` still produces something,
# just one Gatekeeper will block on any other Mac.
DIST_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -o 'Developer ID Application: [^"]*' | head -1)
DIST_IDENTITY := $(if $(DIST_IDENTITY),$(DIST_IDENTITY),-)
# Hardened runtime and a secure timestamp are both required for notarization
# and neither is possible ad-hoc, so they only go on with a real identity.
SIGNFLAGS := $(if $(filter -,$(DIST_IDENTITY)),,--options runtime --timestamp)
# One-time local setup before `make notarize` will work:
#   xcrun notarytool store-credentials moomux-mac-notary \
#     --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
# CI does not use this profile — release.yml passes API-key credentials to
# notarytool directly instead of storing them in a keychain.
NOTARY_PROFILE ?= moomux-mac-notary
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG := dist/Moomux-$(VERSION).dmg
STAGE := .build/dmg
# Deferred (=) rather than immediate (:=): `dev` sets CONFIG per-target, and :=
# would bake in the release path at parse time.
BINDIR = $(shell swift build -c $(CONFIG) --show-bin-path)
BIN = $(BINDIR)/Moomux

.PHONY: build app run dev selfcheck install shot dist notarize clean

build:
	swift build -c $(CONFIG)

# The assert-based checks. Deliberately not part of `build`: they must never be
# built with -O, which deletes every assert (see Scripts/selfcheck.sh).
selfcheck:
	bash Scripts/selfcheck.sh

# Wrap the SwiftPM binary in a bundle. There is no Xcode here, so this is the
# app target. The bundle is not optional for anything that wants a bundle
# identifier — notifications and launch-at-login both need one.
#
# Ad-hoc signing (`-`) is fine while nothing depends on a stable designated
# requirement. When launch-at-login lands, switch to a stable local identity —
# an ad-hoc signature changes every build, which makes that registration
# unreliable. Notifications are *not* affected: measured, the grant is keyed by
# bundle identifier and survives a rebuild with a new CDHash.
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/Moomux
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - --identifier $(BUNDLE_ID) $(APP)

# ARGS is passed through to the app, e.g. `make dev ARGS="--socket /tmp/mmx.sock"`
# to point at a `moomux serve` other than the default one.
ARGS ?=

# Waiting out the old process is not politeness: `open` against an app that is
# still terminating silently does nothing, which reads as a crash on launch.
run: app
	pkill -x Moomux || true
	@while pgrep -x Moomux >/dev/null; do sleep 0.2; done
	open $(APP) --args $(ARGS)

# A debug bundle for the edit-look-edit loop: seconds instead of the release
# build's minute. Same bundle identifier, so nothing else changes.
dev: CONFIG = debug
dev: app
	pkill -x Moomux || true
	@while pgrep -x Moomux >/dev/null; do sleep 0.2; done
	open $(APP) --args $(ARGS)

# Quitting first is the same trap `run` has: a still-running Moomux keeps
# serving the old code, and relaunching just reactivates that process rather
# than starting the copy you installed — which reads as "install did nothing".
# Note that .build/Moomux.app and /Applications/Moomux.app share a bundle
# identifier, so LaunchServices can pick either one; `make clean` after
# installing if you want to be certain which is running.
install: app
	pkill -x Moomux || true
	@while pgrep -x Moomux >/dev/null; do sleep 0.2; done
	rm -rf /Applications/Moomux.app
	cp -R $(APP) /Applications/Moomux.app
	@echo "installed $$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist) to /Applications/Moomux.app"

# A PNG of the running app, for showing a UI change the way the Go side shows
# one with scripts/screenshot.sh.
shot:
	bash Scripts/shot.sh $(OUT)

# A drag-to-Applications disk image — what someone downloading this expects, and
# the one artifact `notarize` stamps. Plain hdiutil, no create-dmg dependency:
# that buys a background image and icon placement, which this doesn't have anyway.
#
# Re-signs first: `app` used the ad-hoc identity, which no other Mac will trust.
# Nothing nested to sign separately — this bundle has no dylib.
dist: app
	@if [ "$(DIST_IDENTITY)" = "-" ]; then \
		echo "WARNING: no Developer ID cert — packaging the ad-hoc build as-is."; \
		echo "Gatekeeper will block it on any other Mac."; \
	else \
		codesign --force --sign "$(DIST_IDENTITY)" $(SIGNFLAGS) --identifier $(BUNDLE_ID) $(APP); \
	fi
	mkdir -p dist
	rm -f $(DMG)
	rm -rf $(STAGE)
	mkdir -p $(STAGE)
	cp -R $(APP) $(STAGE)/
	ln -s /Applications $(STAGE)/Applications
	hdiutil create -volname "Moomux $(VERSION)" -srcfolder $(STAGE) -ov -quiet \
		-format UDZO $(DMG)
	rm -rf $(STAGE)
	@# Signing the image itself (not just the app inside) is what lets the staple in
	@# `notarize` attach to it. No-op on the ad-hoc path.
	$(if $(filter -,$(DIST_IDENTITY)),,codesign --force --sign "$(DIST_IDENTITY)" --timestamp $(DMG))
	@echo "$(DMG)"

# Ships a disk image anyone can open without the right-click > Open dance.
# Stapling writes the notarization ticket into the .dmg, so the file that gets
# uploaded afterwards is the same one that was submitted — no re-packaging step
# that could throw the ticket away.
#
# notarytool and stapler both ship in CommandLineTools, so this needs no Xcode —
# only a Developer ID certificate, which needs a paid Apple Developer account.
# Local use only: CI (release.yml) calls notarytool directly with API-key
# credentials instead of a stored keychain profile.
notarize: dist
	@[ "$(DIST_IDENTITY)" != "-" ] || { \
		echo "No 'Developer ID Application' certificate installed — this build is signed"; \
		echo "ad-hoc and can't be notarized. Needs an Apple Developer Program membership."; \
		exit 1; }
	xcrun notarytool submit $(DMG) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(DMG)
	spctl --assess --type open --context context:primary-signature -vv $(DMG)
	@echo "notarized: $(DMG)"

clean:
	rm -rf .build dist
