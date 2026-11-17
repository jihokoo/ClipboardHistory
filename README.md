# ClipboardHistory

Menu bar clipboard history for macOS. Stores every text you copy into a SQLite
database and shows the history in a popover attached to a menu bar icon.

## Requirements

- macOS 13 (Ventura) or later
- Swift toolchain (Xcode Command Line Tools or Xcode)

## Build & run

```sh
cd ~/ClipboardHistory
./build.sh
open ClipboardHistory.app
```

The menu bar shows a clipboard icon. Click it to open the popover.

## Accessibility permission

The app listens for ⌘C key events via `CGEventTap` in listen-only mode. That
requires Accessibility permission.

On first launch macOS will prompt. Grant it in:

    System Settings → Privacy & Security → Accessibility → enable ClipboardHistory

The app checks for permission every 3 seconds until granted — no relaunch needed.
When capture is off, the menu bar icon turns into a ⚠️ triangle and the popover
shows an orange banner with an **Open Settings** button, so a lost permission is
never silent.

## Keeping the permission across rebuilds

macOS ties the Accessibility grant to the app's **code signature**. An unsigned
app gets a new identity on every rebuild, so the grant silently resets and
capture stops. To make the grant survive rebuilds, create a stable self-signed
signing identity once:

```sh
./scripts/create-signing-cert.sh
```

`build.sh` then signs every build with it automatically (falling back to an
ad-hoc signature, with a warning, if the identity is missing). After switching
from unsigned to signed you must re-grant Accessibility one final time; from then
on it sticks.

## Install & login item

```sh
mv ClipboardHistory.app /Applications/
open /Applications/ClipboardHistory.app
```

To launch on login: System Settings → General → Login Items → add
`ClipboardHistory.app`.

## Where the data lives

`~/Library/Application Support/ClipboardHistory/history.sqlite`

Nothing is ever deleted by the app. To wipe:

```sh
rm ~/Library/Application\ Support/ClipboardHistory/history.sqlite
```

## UI

- 10 entries per page, most recent first
- Each row shows the first 50 characters of the content (full text is stored)
- Click a row → full text in a detail view with a Copy button
- Prev / Next buttons paginate
- Quit exits the app

## Capture scope

Only keyboard-initiated copies (⌘C) are captured. Menu Edit → Copy, right-click
→ Copy, drag operations, `pbcopy` from a shell, and programmatic copies from
other apps will not be recorded.
