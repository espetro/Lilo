# Little window redesign

Research and design note for the Little window, the small floating window for one link or search (`Lilo/LittleWindow/`). Goal: behave like Arc's Little Arc, with Lilo's own command bar as its start view.

## Audit of the current implementation

| Piece | What it is today |
|---|---|
| `LittleWindowHotKey` | Carbon hot key for `littleWindow.new` (default ⌥⌘N), active from any app. It only calls `AppDelegate.newLittleWindow`. |
| `AppDelegate.newLittleWindow` | Finds the owner `MainWindowController` (opening a window if none), calls `openLittleWindow(url: nil)`, then `NSApp.activate`. |
| `MainWindowController+LittleWindow` | `openLittleWindow` builds a `WKWebViewTab` on the Space's profile store and a `LittleWindowController`; `moveLittleWindow` hands the live engine to a tab (or reloads it when the target Space uses another store). |
| `LittleWindowController` | A plain `NSWindow` (`.titled, .closable, .miniaturizable, .resizable`), 900 by 640, transparent title bar with an empty `NSToolbar` (`.unifiedCompact`). The header (an `NSTextField` address pill, copy, an `Open in <Space>` bezel button, a chevron menu) is injected into the title bar container found through `standardWindowButton(.closeButton).superview`. The page is a bare `WKWebView` filling the content view. |

### Why it looks broken

- The header is a subview of AppKit's private title bar container. Its layout (a fixed 78 pt for the traffic lights) knows nothing about the lights' real size or position, which the toolbar style and the window-buttons work (PR #119) move. The lights overlap the pill.
- The title bar is transparent over a translucent toolbar, so whatever is behind the window (another window's heading, in the report) shows through the header.
- With no page the content is a blank `WKWebView`: a white sheet under a toolbar that offers Copy and Open in for a page that does not exist. The window has no start state, so it never looks like a search box.
- The address field is the only entry point: a hand-rolled `NSTextField` with its own URL-or-search parser (`navigate(to:)`) that duplicates the command bar's, and none of its results (history, suggestions, autofill, scopes).

### Why Esc does nothing, and why search is hard to start

- Esc is handled only inside `control(_:textView:doCommandBy:)` while the address field is being edited. It then moves focus to the page, or to nothing: it never closes the window. With the page focused, Esc goes to the page. No key monitor, no `cancelOperation` on the window, no key equivalent.
- `show()` focuses the field with `makeFirstResponder` right after `makeKeyAndOrderFront`; the hot key runs while Lilo is in the background, and `NSApp.activate` follows only after the window is shown, so the field often is not first responder when the user starts typing. A plain `NSWindow` also does not appear over another app's full-screen Space: it would switch Spaces to Lilo's own.

## How Little Arc works

From Arc's public help and write-ups, and from the open source imitations ([wepee/little-browser](https://github.com/wepee/little-browser), [hasdfa/firefox-little-arc](https://github.com/hasdfa/firefox-little-arc), [cdevroe/switcheroo](https://github.com/cdevroe/switcheroo)):

1. A global shortcut (⌥⌘N in Arc) or a link from another app opens a temporary window outside the sidebar.
2. A bare search card shows first: a focused "Search or Enter URL" field, a close button, and result rows below. Click outside, Esc or the close button dismisses it.
3. Choosing a result morphs the card into a small browser window: native traffic lights, an address pill, a copy-link button, and an `Open in <Space>` button (with a shortcut, ⌘O) with a menu to pick another Space. The page fills the rest.
4. The window is disposable. `Open in <Space>` files the page as a tab of that Space and closes the window; closing it just drops the page.
5. In the imitations, Esc closes everywhere and ⌘L brings the search bar back over the page.

Other references: Zen's Glance and Lilo's own Peek are previews over a tab, not windows of their own; Raycast, Alfred and Spotlight are `NSPanel`s (`.nonactivatingPanel`, `canBecomeKey`) with the collection behaviour that lets them float over full-screen Spaces. Floorp and BrowserOS have no equivalent window.

## Design

### Window

- `LittlePanel`, an `NSPanel` subclass: `.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel`, `isFloatingPanel = false`, `hidesOnDeactivate = false`, `canBecomeKey` and `canBecomeMain` true. `collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .moveToActiveSpace]` is not used: `canJoinAllSpaces` and `fullScreenAuxiliary` together are what lets it appear over a full-screen Space without a Space switch, so it works while the main window is in native full screen. The window still takes key focus (`makeKeyAndOrderFront` plus `NSApp.activate`), so the field is focused and the menu shortcuts keep working.
- Content: the page's `WKWebView` below, and above it one chrome `WKWebView` (`lilo-chrome://ui/index.html?little`), the same bundle and scheme as the main window, transparent. Native, not hosted in the title bar: the chrome view is a normal subview, so nothing depends on AppKit's title bar internals.
- Traffic lights are AppKit's: standard size, never moved or resized by us. The chrome reserves the lights' width (read from the close and zoom buttons' frames, sent as `leadingInset`).
- Two modes, one window:
  - **Start**: a compact window (640 by 420, centered at the upper third of the screen the pointer is on), traffic lights hidden, the chrome view covers it all, the page view is hidden.
  - **Page**: after a navigation, the window grows (animated with `animator`, instant under Reduce motion) to the remembered page size (default 900 by 640, same top-center anchor), the traffic lights show, the chrome view shrinks to a 52 pt header strip and the page view fills the rest.
- The window background is the Space's frame color, as today, so the strip reads as part of the window and not as a sheet on top of it.

### Start view: the command bar

`CommandBar.svelte` renders as is, docked (the in-place layout the empty window already uses), inside `LittleApp.svelte`. Its stores run unchanged, fed by the same `SearchBridgeHandler` (history, suggestions, favicons, autofill) the main window registers, on the Little window's own bridge. Two small additions keep the reuse flexible without forking it:

- `CommandBar` takes `onEscape` and `scopes` props: Esc, once there is no scope or move to leave, calls `onEscape`; `scopes` narrows the scope chips to what makes sense with no tabs (all, history).
- `commandBarSearch` gets `setCommandBarActions(false)`: actions (`:` scope, the actions section) are off in the Little window, as every one of them acts on a browser window.

Enter on a URL, a search or a history row posts the same `navigate` command the main window gets; the Little window's bridge handler loads it in its engine and switches to page mode. ⌘↩ on a result opens it as a tab of the Space right away.

### Page view: the minimal chrome

`LittleBar.svelte`, 52 pt, over the Space color:

```text
[ ● ● ● ]  [ 🔍  example.com                 ]  [ 🔗 ]  [ Open in 🌿 Work  ⌘O | ⌄ ]
```

- Address pill: the host, with the load progress as a line along the strip's bottom edge. Click or ⌘L opens the command bar over the page (the chrome view grows to cover the window, the page dims), prefilled with the address and selected; Enter navigates, Esc returns to the page.
- Copy-link button: copies the page's address, with a 1.4 s check mark (the "Status" surface family: a word or mark in place, no toast).
- `Open in <Space>` split button: the primary part opens the page as a tab of the Space the window was opened for, in the main window (the live engine moves when the store matches, `moveLittleWindow`), and closes the Little window; the chevron lists the other Spaces (Private Spaces excluded, as today). ⌘O is its shortcut (the existing File > Open as Tab).
- Keyboard: Tab moves through pill, copy, open and its menu; the menu is a real listbox popover with arrow keys, Return and Esc.

### Esc and focus

| State | Esc |
|---|---|
| Start, query has a scope prefix | Leaves the scope (the command bar's own rule) |
| Start | Closes the window |
| Page, address bar open over the page | Back to the page |
| Page, page or strip focused | Closes the window |

Esc in the page is taken in `LittlePanel.sendEvent` before the page sees it, as Peek and Glance do (a text composition in progress keeps it). A page that needs Esc (a dialog, full-screen video) keeps it: WebKit's own dialogs and full screen run before the key reaches the panel.

Dismissal: in start mode the panel closes when it resigns key (click outside, another app), like Spotlight; a page-mode window stays until closed, it is a window. Cmd+W closes in either. The window being closed with no page records nothing in Recently Closed.

### Efficiency

Nothing runs at idle: no Little window means no chrome view, no bridge, no timers. A window's chrome is released on close. The start view fetches nothing until a key is typed (recent history only on open, as the empty command bar does today).

### Polish and accessibility

Follows [DESIGN.md](../DESIGN.md): 13 px row titles and 17 px field as the command bar has them, the 4 px grid, 24 px controls, 12 px button label, system fonts, SF Symbols-equivalent icons already in the chrome, AA contrast from the Space color's derived text color. Window resizing and the mode change use a 200 ms ease and none at all under Reduce motion (`prefers-reduced-motion` in the chrome, `accessibilityDisplayShouldReduceMotion` natively). Every control is a real button with a label and a tooltip; the strip has no layout jump between loading and loaded.

### Limits and risks

- Appearing over another app's full-screen Space depends on AppKit's panel behaviour across macOS versions; it is verified on a device by hand, not by a test, and falls back to opening on Lilo's own Space.
- The page view's traffic lights and title bar come from AppKit; a future toolbar style change must keep `.fullSizeContentView` and a transparent title bar.

## Not in scope

Changing the shortcut, the link rules or how external links pick the Little window; a Little window's own tabs or history; sharing the chrome's stores with the main window.
