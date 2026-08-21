# Host — Phase 1 prototype

Proof that the window-orchestration layer works. Not a tab switcher yet; a rig for
finding out whether a tab switcher built this way would be any good.

```bash
make identity   # once — see "Accessibility" below
make run        # builds, installs to /Applications, launches
```

Then grant Accessibility, click a tab, and run **Tabs › Run Self-test**.

## What it does

A floating, non-activating strip at the top of a workspace rectangle. Clicking a
tab launches the app if needed, finds its main window, moves it into the rectangle
below the strip, and raises it. `⌥⇧[` and `⌥⇧]` move to the previous and next
apps, wrapping at either end.

- `+` adds an app from `/Applications`, persisted to
  `~/Library/Application Support/Host/workspace.json`. The new tab is selected
  immediately, so the app launches and sizes itself to the workspace there and
  then. Adding an app that is already a tab selects the existing one rather than
  creating a second — tabs are keyed by bundle id throughout, so duplicates would
  fight over the same bound window and geometry state.
- Right-click a tab to remove it. The app keeps running and its window stays put
  — removing a tab is forgetting about an app, not closing it
- **Resizing or moving the hosted window drags the strip with it**: the strip
  re-derives the workspace from the window and matches its width exactly
- Dragging the strip moves the whole workspace, and every tab's window follows,
  not just the one on top
- **Hiding any tab's app hides the whole workspace**, strip included. Unhiding one
  brings the strip back but not the other four — unhiding one tab should not drag
  everything else onto the screen with it.
- Show Desktop sweeps the strip aside with the hosted windows and restores them
  together.
- Drag a tab along the strip to reorder it; the order and the hotkey bindings
  follow
- The **cog** at the right of the strip opens settings: pick the tab bar theme
  and the app icon from 33 themes. The set includes stripes, gradients, night
  skies, polka dots, packed circles, sunflowers, roses, triangles, diamonds,
  waves and bubbles. The icon matches the theme by default; click any icon to break the
  link and choose independently.
  Also on View › Theme and Tabs › Settings (command-comma), for when Host
  happens to be frontmost
- Dock icon and a **Tabs** menu holding Add Application, Self-test, Show Log and
  Accessibility Settings

## The success criterion

One app moving once proves nothing. Every failure mode lives in the *switch*:
windows drifting a few points each time, the strip falling behind the app, focus
bouncing, apps that quietly refuse to resize. So the self-test does ten switches
and reports the worst drift. **Under ~2pt with no visible flicker means Phase 1
is proved.** It has been run and it passes. Anything above that is an app clamping its own geometry, and the log
prints requested vs. actual so you can see which.

## Why `make run` installs to /Applications

Because an Accessibility grant attaches to an app at a path LaunchServices knows
about. A bundle sitting in `build/` has three problems: it is never registered, so
it cannot appear in the Accessibility list at all; the System Settings `+` picker
opens at `/Applications` and will not show it; and `make clean` deletes it,
taking the grant with it. `make install` copies to `/Applications/Host.app` and
registers it with `lsregister`. `make run` does that and then launches.

If macOS shows Host as ticked but windows stop moving, `make reset-permission`
clears the grant so the app prompts again on next launch.

## Accessibility, and why `make identity` exists

macOS keys TCC grants to the code signature. Ad-hoc signatures change on every
build, so every rebuild silently revokes the grant — the app still shows as
ticked in System Settings while every window call fails. That is the single most
annoying thing about this kind of project.

`make identity` creates a self-signed certificate in a dedicated keychain (no
sudo, nothing touches your login keychain). The resulting designated requirement
is:

```
identifier "com.suttree.host" and certificate leaf = H"e8878aef..."
```

No cdhash, so it is stable across rebuilds. Grant once.

`security find-identity -v` will still not list it — `-v` means "chains to a
trusted root", which a self-signed cert never does. `codesign` accepts it anyway.
You also have an expired `Apple Development: Duncan Gough` cert in the login
keychain; if you renew it, set `IDENTITY` in the Makefile to that instead.

Note this app can never be sandboxed, because the Accessibility API requires an
unsandboxed process. Developer ID and notarization only — no Mac App Store.

## Why settings are on the strip, not just in the menu bar

The menu bar belongs to whichever app is frontmost, and clicking a tab makes that
some other app immediately — so Host's own menus are unreachable in practice.
Anything you need while using Host has to be on the strip itself. The menu items
still exist and work when Host does happen to be frontmost; they just cannot be
the only way in.

The settings window is deliberately not modal: you want the strip restyling
itself behind it as you click through the themes.

## Why the strip changes level rather than hiding

It floats above normal windows so it can sit on top of the app it is hosting.
Left at that level it would also sit on top of every unrelated window on screen.
Lowering the level permanently is no good either -- it would be buried under the
very window it belongs to.

So the level follows the frontmost app: floating while a hosted app is in front,
normal otherwise. It stays on screen throughout, and any other window is free to
cover it. Ordering it out was the first attempt at this and overshot: the strip
vanished the moment a hosted app lost focus, which made the workspace look like
it had gone away.

Full screen is handled by the Space, not by the level. The panel is deliberately
**not** `.canJoinAllSpaces`: a full-screen window gets a Space of its own, and
that flag made the strip follow it there and sit on top of full-screen video.
Without it the strip stays on the Space it belongs to, alongside the hosted
windows. `open -a Host --args --fullscreen-test` checks this by full-screening
the active tab and reporting whether the strip is genuinely being displayed --
`isVisible` cannot answer that, since it stays true for a window on an inactive
Space, so the check goes through `CGWindowListCopyWindowInfo`.

## Themes

`Sources/Theme.swift` holds the palettes and pattern renderers;
`Sources/IconRenderer.swift` composites the line drawing onto one. Both are
compiled into the app *and* into the icon tool, so the .icns on disk and the icon
the app draws at runtime come from the same code.

The Dock icon is redrawn in process rather than swapped on disk. Rewriting a
signed bundle's .icns would break the code signature and take the Accessibility
grant with it. `NSApplication.applicationIconImage` is an in-memory property
macOS forgets on relaunch, so the stored theme is re-applied at every launch.

Every tab sits on a solid card in the theme's `chip` colour, off-white for the
daylight themes and dark for Galaxy, Starry Night and Hacker. That card is what
lets the stripes be as bold as they like: text never touches the background, so
legibility stops depending on which band happens to pass behind a given tab.
Rainbow is the case that proves it.

The active tab gets bold type and stays fully opaque. Inactive tabs fade to 52%
as a complete unit, including the icon, label and card, so the current app is
obvious without changing the tab layout.

Two details that matter to how it looks:

- On the icon the palette is fitted across the shape exactly **once**. Tiling it
  makes the pale first band reappear in the bottom-right corner and the sunset
  stops reading as a sunset. On the strip it tiles, because one pass across
  something that long would stretch each band into an unreadable smear.
- The icon is a superellipse, not a rounded rectangle. macOS icon corners are
  continuous curves and a circular-cornered rect looks wrong beside real icons.

`make icon THEME=galaxy` changes which theme the bundled .icns ships in; the
running app can switch freely regardless.

## Decisions worth knowing about

**There is no host window.** The plan called for an 800×600 window with a tab bar
at the top and the app window filling the rest. But the external window is always
drawn over anything we could put back there, so that window would be invisible —
and it would sit in the z-order fighting the app it just raised. All that is
actually needed is a rectangle and a floating strip. `Workspace` is the rectangle.

**No digit shortcuts.** Host does not claim Command, Control or Option with the
number row. Those combinations belong to apps, Mission Control and keyboard
layouts. Option-3 must remain available for typing `#`, for example.

**Carbon `RegisterEventHotKey`, not `NSEvent.addGlobalMonitorForEvents`.** A
global monitor can observe a keystroke but cannot consume it, so the frontmost app
would receive it too. Carbon swallows the event and works from an accessory app
that is never active.

**All AX traffic is off the main thread.** `AXUIElementCopyAttributeValue` is
synchronous IPC into the target process; on the main thread one beachballed app
stalls the UI on every read. Everything runs on a serial queue with a 0.25s
messaging timeout instead of the 6s default.

**Position is written twice, either side of size.** Windows with a minimum size
clamp the resize and then move themselves to stay on screen, undoing the first
position write.

**The strip follows the window, not the other way round.** When the user resizes
the hosted window, the workspace rectangle is re-derived from the window and the
strip matches its width. Move and resize notifications are coalesced with a
generation counter, because a fast drag fires them dozens of times a second and a
backlog of stale frames makes the strip visibly lag. A flag suppresses the reverse
path so our own repositioning is not mistaken for a user drag.

**Apps are launched with `activates = true`.** Document-based apps commonly create
no window at all when launched quietly: TextEdit launches, reports zero AX windows
indefinitely, and the tab never appears. If a running app still has no window it
gets one reopen nudge, which is what makes a document app produce an untitled
document or its open panel.

**Raising is verified, not assumed.** Neither activation route is reliable on its
own: `NSRunningApplication.activate` is refused when Host lacks activation rights,
and `AXFrontmost` can return success while the app still does not come forward.
Both are tried, and 0.3s later the frontmost app is checked and the raise retried
if it missed. Without that a tab occasionally placed its window correctly and left
it sitting behind the app you were already on, which looks like the tab doing
nothing.

**Raising uses AXFrontmost, not just NSRunningApplication.activate.** Since macOS
14 an app may only activate another app while it holds activation rights, and the
tab strip is a non-activating panel, so Host is almost never frontmost and the
request is refused. The window gets placed correctly and then never comes forward,
which looks exactly like the tab doing nothing. Setting `AXFrontmost` goes through
the Accessibility API, which is not subject to that restriction.

**Geometry notifications caused by our own placement are suppressed for a second
after we place a window.** Otherwise an app with a minimum window size reports its
clamped frame, that gets read back as the user resizing the workspace, and the
size the user actually chose is silently replaced by whatever the least flexible
app in the workspace permits. Photos is the example here: it will not go below
about 615pt tall, and without the suppression one visit to the Photos tab
permanently resized everything else.

**Outgoing apps are not hidden, just covered.** `hide()`/`unhide()` brings the
Dock genie animation with it, which is exactly the flicker worth avoiding. Every
tab shares one rectangle, so the incoming window covers the outgoing one.

**AX coordinates are top-left origin off the primary display; Cocoa is
bottom-left.** `Coords.flip` is the whole of it, and getting it wrong is why
windows end up mirrored vertically.

## Known limits

- **One Space, no full-screen apps.** Not an issue here — Spaces are unused — but
  worth recording: a window on a Space you are not on cannot be repositioned by
  any public API. yabai only solves this by disabling SIP.
- The system menu bar still belongs to whichever app is frontmost. This will feel like
  fast app switching with a persistent strip, not like one app with tabs. That is
  the gap most likely to disappoint at the end of Phase 2 — worth sitting with
  before building more.
- **Apps with a minimum window size overflow the workspace rather than resizing
  it.** Photos will not go below ~615pt tall. It is placed at the workspace origin
  and simply extends past the bottom; the strip and every other tab keep the size
  you chose. The log says so explicitly when it happens.
- One window per app. A second document window is not tracked; the AX observer
  notices and unbinds, and the next click rebinds to whatever is main.
- Multi-monitor is untested.

## Debugging

Everything is logged to `~/Library/Logs/Host.log` as well as the in-app log window.

- **Tabs › Diagnose Tabs** — read-only report per app: window count, role, subrole,
  whether position and size are settable, and whether Host would accept that
  window. Launches nothing, moves nothing. Also runs at startup.
- `open -a Host --args --cycle` — visit every tab once, logging what actually ended
  up frontmost. Placement succeeding tells you nothing about z-order, and that
  distinction has already been one real bug.
- `open -a Host --args --add <bundle-id>` — exercise the add path without driving
  the open panel.
- `open -a Host --args --theme <id>` — switch theme at launch, for checking them.
- `open -a Host --args --move-tab <from> <to>` — reorder without a mouse.
- `open -a Host --args --hide-test` — hide the first tab's app and report which of
  the others followed.
- `open -a Host --args --bar-preview <path>` — render the tab strip to a PNG, for
  checking the look without a screen recording permission.
- `open -a Host --args --resize-test` — resize the first tab to an odd size, then
  switch through the others, logging requested vs actual for each. This is what
  caught the minimum-size problem.

## Layout

```
Sources/
  AX.swift             low-level AX helpers, coordinate flip, permission, logging
  WindowManager.swift  launch / find / place / raise, off-main-thread, AX observers
  HotKeys.swift        Carbon global hotkeys
  Workspace.swift      tab model, workspace rectangle, JSON persistence
  TabStrip.swift       the floating non-activating panel and its buttons
  SelfTest.swift       ten-switch drift measurement, log window
  AppDelegate.swift    wiring, status item, permission nag
tools/make-identity.sh stable self-signed signing identity
  Theme.swift          palettes and pattern drawing, shared by the
                       tab strip and the app icon
  IconRenderer.swift   masks and crops the line art, composites it onto a theme
  SettingsWindow.swift the theme and app icon pickers, opened from the cog
tools/icongen/         writes the .iconset; `make icon` regenerates AppIcon.icns
Resources/artwork.png  the line drawing, black on white
```
