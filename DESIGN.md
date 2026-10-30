# Dockyard design

How Dockyard looks and reads, for anyone adding or changing UI. The behaviour spec is `docs/internal/HANDOFF.md`; colours come from its section 12.

## Principles

- **A Mac app first.** Use system controls, SF Symbols, the system font and grouped `Form`s. Add custom drawing only where AppKit or SwiftUI has nothing suitable (badges, status dots, the drawer).
- **Dense but calm.** People keep hundreds of connections and thousands of files open. Lists use small controls and 22 pt rows. Colour is kept for state (connected, PROD, root, errors), not decoration.
- **Safe by default.** Destructive or production actions are visible and reversible: PROD badges, read-only locks, undo toasts, Trash over delete.
- **Nothing to set up.** Connections save themselves, sessions restore themselves and defaults work. Settings are for exceptions.

## Colour

Every colour is a named asset in `App/Resources/Assets.xcassets` with a dark variant, read through `Palette` ([Palette.swift](App/Sources/Support/Palette.swift)). Don't hard-code colours in views.

| Token | Light | Dark | Use |
|---|---|---|---|
| `Ground` | `#FFFFFF` | `#1E1E20` | List and content backgrounds |
| `Chrome` | `#F4F4F6` | `#2A2A2D` | Toolbar, tab strip |
| `ChromeAlt` | `#F9F9FA` | `#252528` | Sidebar, path bars, alternate rows |
| `Border` | `#DCDCE1` | `#3D3D42` | Hairlines between regions |
| `TextPrimary` | `#1D1D1F` | `#F2F2F4` | Body text |
| `TextSecondary` | `#5F6168` | `#A0A2AA` | Captions, sizes, dates, paths |
| `Selection` | `#DCE7F7` | `#24406B` | Selected rows in custom lists |
| `AccentColor` | `#0B63CE` | `#4C9AFF` | Default buttons, links, NEW badge |
| `StatusGreen` | `#1F9D55` | `#34C26F` | Connected |
| `StatusAmber` | `#E5A11A` | `#F0B73A` | Connecting, reconnecting, warnings, running out |
| `StatusGrey` | `#B9BAC0` | `#6B6C73` | Disconnected, failed |
| `ProdBadgeBg` / `Fg` | `#F8E3D6` / `#8A3B12` | `#5A2C12` / `#F4B48C` | PROD badge |
| `CloudBadgeBg` / `Fg` | `#E6E1F7` / `#4A2F96` | `#3A2F66` / `#C4B5F5` | CLOUD badge |
| `RootBadgeFg` | `#7A4B00` | `#F2C45A` | ROOT badge (on amber at 25%) |
| `DrawerBg` | `#1B1B1F` | `#1B1B1F` | The drawer, dark in both appearances |

The log uses its own set on the dark drawer: `LogStatus` `#B9BAC0`, `LogCommand` `#6CB2FF`, `LogResponse` `#7FD99B`, `LogWarning` `#F0B73A`, `LogError` `#FF6B6B`.

Status is never shown by colour alone: a status dot carries an accessibility label, and errors also get a symbol or text.

## Type

The system font (SF Pro) at fixed sizes. Don't use Dynamic Type styles in dense lists.

| Size | Weight | Use |
|---|---|---|
| 13 | regular / medium | Body, form rows, file names |
| 12 | regular / semibold | Toasts, drawer controls, secondary rows |
| 11 | regular / semibold | Captions under form rows, column headers, section labels |
| 10 | semibold | Counts, small labels |
| 9 | bold | Badges (PROD, CLOUD, NEW, ROOT) |
| 22–26 | regular | Empty-state symbols |

Monospaced: `Font.mono` (12) for the log, terminal-adjacent text and paths that need to line up, and `Font.monoSmall` (11).

## Shape and spacing

- Corner radii: 3 for badges, 5–6 for buttons, fields and tabs, 8 for cards and grouped boxes, 10 for windows and popovers.
- Spacing follows a 4 pt grid; 8, 10 and 12 are the common gaps and paddings.
- Hairlines are 1 px `Border`. Use shadows only on floating things such as menus, popovers and toasts.
- Most toolbars and drawer controls use `.controlSize(.small)`.

## Layout

- **Main window**: at least 980 × 620. A tab strip of connections across the top, a sidebar of connections, then the local pane and server pane side by side. Grouped tabs show several servers in columns.
- **Panes**: each has folder tabs, a path bar with breadcrumbs, an optional folder tree and an AppKit file table (22 pt rows, no intercell spacing).
- **Drawer**: along the bottom, always `DrawerBg`. Default height 220, resizable from 120 to 700 by its handle. Its tabs are a segmented control (Log, Terminal, Transfers, Scratch) with tab-specific controls to the right and a close button at the end.
- **Sheets and settings**: grouped `Form`s, about 520 wide. The connection manager is at least 900 × 520.

## Components

- **Badge** (`Badge`): PROD, CLOUD, NEW, ROOT. Short caps, 9 pt bold, radius 3.
- **Status dot** (`StatusDot`): 8 pt circle in the status colours, with a label for VoiceOver.
- **Toasts** (`ToastStack`): short confirmations with an SF Symbol, stacked, fading in over 0.2 s. They offer Undo when the action can be undone. Use them for anything that happened out of sight (a background download, an upload after editing, an undoable move). Errors use `isError`.
- **Captions**: an 11 pt `TextSecondary` line under a form row that explains a consequence, not the control.
- **Confirmations**: an `NSAlert` or confirmation dialog only for destructive or production actions; everything else can be undone.

## Writing

- Plain, short sentences. Say what happens: "Blocks uploads, deletes, renames and permission changes," not "Enables read-only mode."
- Sentence case for labels, buttons and menu items ("Mount in Finder", "Download to Scratch").
- An ellipsis (`\u{2026}`) on any command that opens a dialog or asks for more input ("Choose…", "Empty Scratch…").
- Canadian/British spelling in the UI: colour, authorise.
- Name things after the user's world (This Mac, server, connection, folder), not the protocol's.
- Field prompts state the default: "Default: your home folder", "Optional", "Stored in Keychain".

## Accessibility

- Every icon-only button has an `accessibilityLabel`.
- Text meets 4.5:1 against its background in both appearances; check any new colour pairing in light and dark.
- Keyboard first: common actions get a shortcut (Space for Quick Look, ⌘T for a tab), and new commands belong in the menu bar as well as in context menus.

## Context menus

- Leave out items that don't apply rather than dimming them.
- Top level for daily actions (open, preview, transfer, copy a path, rename, delete); one level of submenu for occasional ones, grouped by subject (**Archive ▸**, **More ▸**). No deeper nesting.
- A right-click on empty space is about the folder: clear the selection and show the folder's menu.
- Show a shortcut next to an item only when the menu bar has the same command.

## Scratch

A Scratch tab in the drawer, **Download to Scratch** (⌥⌘D), a Scratch section in Settings and a Local folder section in the site editor. Time left uses `StatusGreen` and turns `StatusAmber` under an hour. Mockups: the "Dockyard Scratch Folder" design canvas.
