# Nook

Tighter menu bar. One icon, one menu: set the gap between menu bar icons,
show or hide Apple's own icons, add spacers.

macOS squandered the menu bar's space; Nook gives it back — 0–16 pt spacing
instead of the system default, applied to every icon.

## Install

Download `Nook.zip` from the [latest release](https://github.com/justaicode/nook/releases/latest),
unzip, drop `Nook.app` into `/Applications`. Notarized by Apple — it opens
without warnings.

## What it does

- **Gap between icons** — 0–16 pt, or back to System default
- **Apple icons** — show/hide Wi-Fi, Bluetooth, Sound, and friends
- **Spacers** — insert empty gaps to group your icons
- **Relaunch a menu-bar utility** — so third-party icons pick up the new gap
- **Start at login**

## How it works

The spacing is macOS's own hidden preference (`NSStatusItemSpacing` /
`NSStatusItemSelectionPadding`); Nook sets it and nudges Control Center to
apply it. Apple icons toggle through Control Center's preferences. Spacers
are tiny helper apps inside the bundle — that's the only way macOS allows an
independent, draggable blank slot.

Everything happens locally. No network, no analytics, ~200 KB.

## Requirements

macOS 26 (Tahoe) — that's where it's built and tested. Apple silicon.

## Build from source

```
./build.sh --run
```

One Swift file for the app, one for the spacer helper. No dependencies, no
Xcode project.
