APP      := Host
BUNDLE   := build/$(APP).app
SOURCES  := $(wildcard Sources/*.swift)
TARGET   := arm64-apple-macosx13.0
# Deliberately not "find-identity -v": -v lists only identities that chain to a
# trusted root, and a self-signed development certificate never will. codesign
# accepts it regardless, which is all we need.
IDENTITY ?= $(shell security find-identity -p codesigning 2>/dev/null | grep -o '"Host Dev"' | head -1 | tr -d '"')

.PHONY: all run install test clean identity icon reset-permission

LSREG   := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
INSTALL := /Applications/$(APP).app

all: $(BUNDLE)

$(BUNDLE): $(SOURCES) Resources/Info.plist Resources/AppIcon.icns Resources/artwork.png Makefile
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@cp Resources/artwork.png $(BUNDLE)/Contents/Resources/artwork.png
	swiftc -target $(TARGET) -O -o $(BUNDLE)/Contents/MacOS/$(APP) $(SOURCES)
ifeq ($(IDENTITY),)
	@echo "--- signing ad hoc: macOS will revoke Accessibility on every rebuild."
	@echo "--- run 'make identity' once to fix that."
	@codesign --force --sign - $(BUNDLE)
else
	@echo "--- signing with stable identity: $(IDENTITY)"
	@codesign --force --sign "$(IDENTITY)" $(BUNDLE)
	@codesign -d -r- $(BUNDLE) 2>&1 | grep designated || true
endif
	@echo "built $(BUNDLE)"

# Install before running, deliberately.
#
# Accessibility grants attach to an app at a path LaunchServices knows about. A
# bundle sitting in build/ is invisible to the System Settings picker (which
# starts at /Applications) and is destroyed by `make clean`, taking the grant
# with it. Installing gives a stable home and gets the app registered so it can
# appear in the Accessibility list at all.
install: $(BUNDLE)
	@pkill -x $(APP) 2>/dev/null; true
	@rm -rf $(INSTALL)
	@cp -R $(BUNDLE) $(INSTALL)
	@$(LSREG) -f $(INSTALL)
	@echo "installed $(INSTALL)"

run: install
	@open $(INSTALL)

test:
	@mkdir -p build
	@swiftc -o build/tab-navigation-tests Sources/TabNavigation.swift Tests/TabNavigationTests.swift
	@build/tab-navigation-tests

# Clears a stale grant when macOS has the app ticked but window calls still fail.
# The app will prompt again on next launch.
reset-permission:
	@tccutil reset Accessibility $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Resources/Info.plist)
	@echo "grant cleared -- relaunch and approve again"

# ARTWORK is black line art on a white ground; it is composited with multiply so
# the white drops out. Override the path if the source moves.
ARTWORK ?= Resources/artwork.png
# Which theme the bundled .icns is drawn in. The running app can switch freely
# via the View menu; this is only what a fresh install starts as.
THEME   ?= sunset-stripes

icon:
	@mkdir -p build
	@swiftc -o build/icongen tools/icongen/main.swift Sources/Theme.swift Sources/IconRenderer.swift
	@./build/icongen build/Host.iconset $(ARTWORK) $(THEME)
	@iconutil -c icns build/Host.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

# Accessibility grants are keyed to the code signature. An ad-hoc signature
# changes on every build, so macOS silently revokes the grant and you re-approve
# by hand each time. A self-signed certificate keeps the signature stable.
identity:
	@./tools/make-identity.sh

clean:
	rm -rf build
