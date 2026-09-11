# Machine-local overrides (SDK pins, build-system choice) that don't belong in
# a Makefile every checkout shares — see Makefile.local.example.
-include Makefile.local

CONFIG ?= release
# Extra flags for every `swift build` invocation. Empty by default; a machine
# with a broken default toolchain sets this in Makefile.local instead of here.
SWIFT_BUILD_FLAGS ?=
BUNDLE_ID = app.moomux.Moomux
# `run`/`dev` build a *different app* as far as LaunchServices is concerned.
# Sharing one identifier with the installed copy meant `open .build/Moomux.app`
# could reactivate /Applications/Moomux.app instead of the build you just made
# — which is why both targets used to `pkill -x Moomux`, and that killed every
# Moomux on the machine: the installed app, and every other worktree's.
# Four of those in twenty-five minutes read exactly like the app crashing (they
# are SIGTERM, so there is no crash report to find). Own identifier, own
# process, kill only our own.
#
# One identifier for every worktree's dev build, not one each: a per-worktree
# identifier would make every worktree a new app to macOS, each prompting for
# its own notification authorization. The cost is that two worktrees' dev builds
# share an identifier and plain `open` would reactivate whichever is already
# running, so `run`/`dev` pass `open -n`.
DEV_BUNDLE_ID := app.moomux.Moomux.dev
APP := .build/Moomux.app
# The one process `run`/`dev` may kill: the one they launched, from this
# worktree. Other worktrees have another $(CURDIR); the installed app has
# another path entirely. `[M]` is not decoration: `pgrep -f` matches the whole
# command line of every process, including the `sh -c while pgrep -f ...` that
# runs the wait loop — a plain path matches that shell and the loop never ends.
# The bracket makes the pattern match the executable and not its own spelling.
DEV_PAT = $(CURDIR)/$(APP)/Contents/MacOS/[M]oomux
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
# How `notarize` authenticates. CI has no keychain to store a profile in, so
# release.yml overrides this with the API/app-password credentials directly —
# same recipe both ways, which is the point: the stapling order below is easy
# to get wrong and there should only be one copy of it.
NOTARY_ARGS ?= --keychain-profile $(NOTARY_PROFILE)
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG := dist/Moomux-$(VERSION).dmg
VOLNAME := Moomux $(VERSION)
# The intermediate read-write image: the only kind whose volume attributes can
# be changed, which is what the volume icon needs.
DMGRW := .build/Moomux-rw.dmg
STAGE := .build/dmg
# notarytool takes a zip, not a bundle — a .app is a directory.
APPZIP := .build/Moomux.zip
# Deferred (=) rather than immediate (:=): `dev` sets CONFIG per-target, and :=
# would bake in the release path at parse time.
BINDIR = $(shell swift build -c $(CONFIG) $(SWIFT_BUILD_FLAGS) --show-bin-path)
BIN = $(BINDIR)/Moomux

.PHONY: build app run dev selfcheck warnings install shot signapp dmg dist notarize clean

build:
	swift build -c $(CONFIG) $(SWIFT_BUILD_FLAGS)

# Every warning in *our* sources, without the `rm -rf .build` that idiom used
# to need. swift build only re-emits diagnostics for files it recompiles, so
# something has to force a full recompile — but nuking .build also re-downloads
# libghostty's 77MB xcframework and rebuilds the Swift layer around it, which
# can never produce a warning we can act on. Touching our own sources
# recompiles exactly the module we care about, and in seconds.
warnings:
	@find Sources -name '*.swift' -exec touch {} +
	@swift build -c $(CONFIG) $(SWIFT_BUILD_FLAGS) 2>&1 | grep "warning:" | sed 's/.*warning: //' | sort -u

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
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp Resources/PeekabooPlate.png $(APP)/Contents/Resources/PeekabooPlate.png
	cp Resources/icons/moomux-terminal-nose.svg $(APP)/Contents/Resources/moomux-terminal-nose.svg
	cp Resources/icons/moomux-menubar.svg $(APP)/Contents/Resources/MenuBarIcon.svg
	# libghostty's terminfo and shell integration, shipped as a SwiftPM resource
	# bundle. `Bundle.module` finds it in Contents/Resources; without it a pane's
	# child gets TERM=xterm-ghostty with no terminfo to match, and tmux attaches
	# to a terminal it cannot describe.
	# ghostty's themes, which libghostty-spm does not ship. They go *into* that
	# bundle — ghostty resolves `theme = <name>` under GHOSTTY_RESOURCES_DIR,
	# which the package points at the bundle's `Ghostty` directory. Copied into
	# $(BINDIR)'s bundle before it is copied on, so the unbundled `.build`
	# binary resolves them too. Without them one `theme =` line makes
	# `prepareConfig` reject the user's whole config (see AppState.paneConfig).
	rm -rf $(BINDIR)/GhosttyKit_GhosttyTerminal.bundle/Ghostty/themes
	cp -R Resources/ghostty-themes $(BINDIR)/GhosttyKit_GhosttyTerminal.bundle/Ghostty/themes
	cp -R $(BINDIR)/GhosttyKit_GhosttyTerminal.bundle $(APP)/Contents/Resources/
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" $(APP)/Contents/Info.plist
	codesign --force --sign - --identifier $(BUNDLE_ID) $(APP)

# ARGS is passed through to the app, e.g. `make dev ARGS="--socket /tmp/mmx.sock"`
# to point at a `moomux serve` other than the default one.
ARGS ?=

# Waiting out the old process is not politeness: `open` against an app that is
# still terminating silently does nothing, which reads as a crash on launch.
run: BUNDLE_ID = $(DEV_BUNDLE_ID)
run: app
	pkill -f "$(DEV_PAT)" || true
	@while pgrep -f "$(DEV_PAT)" >/dev/null; do sleep 0.2; done
	open -n $(APP) --args $(ARGS)

# A debug bundle for the edit-look-edit loop: seconds instead of the release
# build's minute.
dev: CONFIG = debug
dev: BUNDLE_ID = $(DEV_BUNDLE_ID)
dev: app
	pkill -f "$(DEV_PAT)" || true
	@while pgrep -f "$(DEV_PAT)" >/dev/null; do sleep 0.2; done
	open -n $(APP) --args $(ARGS)

# Quitting first is the same trap `run` has: a still-running Moomux keeps
# serving the old code, and relaunching just reactivates that process rather
# than starting the copy you installed — which reads as "install did nothing".
# Only the installed one, though: a `dev` build is a different bundle
# identifier and a different process, and there is no reason to take it down.
# `$(MAKE) app` rather than a prerequisite: `app` is phony, so in a single
# `make dev install` it would be built once — under `dev`'s CONFIG and
# BUNDLE_ID — and this would then copy a debug bundle carrying the *dev*
# identifier into /Applications, where it would silently lose the release app's
# notification grant. A sub-make gets its own variables.
install:
	$(MAKE) app CONFIG=release BUNDLE_ID=app.moomux.Moomux
	pkill -f "/Applications/Moomux.app/Contents/MacOS/[M]oomux" || true
	@while pgrep -f "/Applications/Moomux.app/Contents/MacOS/[M]oomux" >/dev/null; do sleep 0.2; done
	rm -rf /Applications/Moomux.app
	cp -R $(APP) /Applications/Moomux.app
	@echo "installed $$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist) to /Applications/Moomux.app"

# A PNG of the running app, for showing a UI change the way the Go side shows
# one with scripts/screenshot.sh.
shot:
	bash Scripts/shot.sh $(OUT)

# A drag-to-Applications disk image — what someone downloading this expects, and
# the one artifact `notarize` stamps. Plain hdiutil, no create-dmg dependency:
# that buys a background image and icon placement, which this doesn't have.
#
# Re-signs first: `app` used the ad-hoc identity, which no other Mac will trust.
# Nothing nested to sign separately — this bundle has no dylib.
# Same reason as `install` above: never package whatever `app` another goal
# in the same invocation happened to leave in .build.
signapp:
	$(MAKE) app CONFIG=release BUNDLE_ID=app.moomux.Moomux
	@if [ "$(DIST_IDENTITY)" = "-" ]; then \
		echo "WARNING: no Developer ID cert — packaging the ad-hoc build as-is."; \
		echo "Gatekeeper will block it on any other Mac."; \
	else \
		codesign --force --sign "$(DIST_IDENTITY)" $(SIGNFLAGS) --identifier $(BUNDLE_ID) $(APP); \
	fi

# Wraps whatever $(APP) currently is, ticket included if one has been stapled —
# so `notarize` staples the app *before* calling this, and the copy the user
# drags to /Applications carries its own ticket.
dmg:
	mkdir -p dist
	rm -f $(DMG) $(DMGRW)
	rm -rf $(STAGE)
	mkdir -p $(STAGE)
	cp -R $(APP) $(STAGE)/
	ln -s /Applications $(STAGE)/Applications
	@# The mounted image gets the app's own icon instead of a generic white drive.
	@# It needs both halves: .VolumeIcon.icns at the volume root, and the volume's
	@# custom-icon bit, which can only be set on a *mounted read-write* image — so
	@# build UDRW, flag it, and convert to the compressed image we actually ship.
	@# The flag survives the conversion (measured with GetFileInfo -a).
	cp Resources/AppIcon.icns $(STAGE)/.VolumeIcon.icns
	hdiutil detach -quiet "/Volumes/$(VOLNAME)" 2>/dev/null || true
	hdiutil create -volname "$(VOLNAME)" -srcfolder $(STAGE) -ov -quiet \
		-format UDRW $(DMGRW)
	hdiutil attach -nobrowse -quiet $(DMGRW)
	SetFile -a C "/Volumes/$(VOLNAME)"
	hdiutil detach -quiet "/Volumes/$(VOLNAME)"
	hdiutil convert $(DMGRW) -format UDZO -quiet -o $(DMG)
	rm -f $(DMGRW)
	rm -rf $(STAGE)
	@# Signing the image itself (not just the app inside) is what lets the staple in
	@# `notarize` attach to it. No-op on the ad-hoc path.
	$(if $(filter -,$(DIST_IDENTITY)),,codesign --force --sign "$(DIST_IDENTITY)" --timestamp $(DMG))
	@echo "$(DMG)"

# Sub-makes rather than prerequisites: `make -j` is free to run prerequisites
# of a phony target in parallel, and packaging half a signed bundle is not a
# failure that announces itself.
dist:
	$(MAKE) signapp
	$(MAKE) dmg

# Ships a disk image anyone can open without the right-click > Open dance.
#
# Two submissions, in this order, and the order is the whole point: a ticket
# stapled to the .dmg covers the image only. The app copied *out* of it has no
# ticket of its own, so it opens solely while Gatekeeper can reach Apple to look
# the notarization up — offline, behind a captive portal, or on a slow CloudKit
# day it is "Apple could not verify Moomux is free of malware", on a build that
# assesses as `accepted` on the machine that made it. That shipped once. So:
# notarize and staple the app, then build the image around the stapled app and
# notarize that too. There is no staple-it-afterwards option — a mounted image
# is read-only.
#
# Stapling does not break the signature: the ticket lands at
# Contents/CodeResources, which codesign's default rules exclude from the seal.
#
# notarytool and stapler both ship in CommandLineTools, so this needs no Xcode —
# only a Developer ID certificate, which needs a paid Apple Developer account.
# CI runs this same target with NOTARY_ARGS overridden.
notarize:
	@[ "$(DIST_IDENTITY)" != "-" ] || { \
		echo "No 'Developer ID Application' certificate installed — this build is signed"; \
		echo "ad-hoc and can't be notarized. Needs an Apple Developer Program membership."; \
		exit 1; }
	$(MAKE) signapp
	rm -f $(APPZIP)
	ditto -c -k --keepParent $(APP) $(APPZIP)
	xcrun notarytool submit $(APPZIP) $(NOTARY_ARGS) --wait
	xcrun stapler staple $(APP)
	$(MAKE) dmg
	xcrun notarytool submit $(DMG) $(NOTARY_ARGS) --wait
	xcrun stapler staple $(DMG)
	@# Both checks, because either one passing alone is the bug above.
	xcrun stapler validate $(APP)
	spctl --assess --type open --context context:primary-signature -vv $(DMG)
	@echo "notarized: $(DMG)"

clean:
	rm -rf .build dist
