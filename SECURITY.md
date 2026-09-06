# Security and privacy — this fork

Audited 2026-09-06 against the `lionel` branch. This file describes what the app touches, what
leaves the machine, and what is written down. It is written to be checkable: every claim below
corresponds to something greppable in this repository.

## What leaves this Mac

Four network destinations exist in the entire source tree. There is **no telemetry, no
analytics, and no crash reporting.**

| Destination | Sent | When |
|---|---|---|
| `api.open-meteo.com` | latitude and longitude | weather backdrop refresh |
| `geocoding-api.open-meteo.com` | **a place name you typed in settings** | once, to turn that name into coordinates, which are then cached in `Defaults` |
| `lrclib.net` | **the current track title and artist** | lyrics lookup while music plays |
| `assets9.lottiefiles.com` | nothing identifying | one animation asset |

`http://localhost:26538` also appears: that is the YouTube Music Desktop companion API on your
own machine. It never leaves the loopback interface.

Two things worth being explicit about:

- **Location is never read.** The weather feature geocodes a name you type. `CoreLocation` is
  not used anywhere in this app, and the coordinates come from that lookup, not from GPS or
  Wi-Fi positioning.
- **Lyrics lookup transmits what you are listening to.** That is inherent to fetching lyrics
  from a remote database, and it is the only feature that sends activity off the machine. It
  can be turned off in settings.

**Sparkle's update feed is removed on this branch** (commit `7cd9650`), so this build also does
not contact an update server or report its version anywhere.

## What is never transmitted

- **Audio.** The visualiser opens a CoreAudio process tap, runs an FFT in-process, and keeps
  only band magnitudes. No audio is written to disk or sent anywhere.
- **API usage figures.** The stats strip reads `~/.local/share/claude-router/requests.log`
  locally and renders it locally. Nothing from it is transmitted.
- **Calendar and reminder contents**, Bluetooth device names, and network details.

## What is written to the system log

This is the honest weak spot, and it is in our own code rather than a dependency.

- **19 `NSLog` calls interpolate a value.** `NSLog` writes to the unified system log, which is
  persisted and readable by any process that can run `log show`. The values include display
  names, the selected camera's name, and playback state.
- **66 `print` calls interpolate a value.** For an app launched by Finder these go to a stdout
  that is discarded, so they are not a disclosure — but they are not free either.
- **Zero of these are behind `#if DEBUG`.** They all run in the Release build.

**Recommended before the next release handed to anyone:** gate the `NSLog` calls behind
`#if DEBUG`, or move them to `Logger` with the default privacy (OSLog redacts interpolated
values as `<private>` unless explicitly marked `.public` — nothing in this tree marks anything
`.public`).

## Subprocesses

The app spawns two executables:

- **`/usr/bin/perl`** — see below.
- **`/usr/bin/zip`** — the file shelf, to compress a dropped selection.

## The vendored binary, stated plainly

`mediaremote-adapter/` contains a **prebuilt Mach-O universal binary checked into the
repository** (`MediaRemoteAdapter.framework`, plus a `MediaRemoteAdapterTestClient`
executable), from [Jonas van den Berg's mediaremote-adapter](https://github.com/ungive/mediaremote-adapter),
BSD 3-Clause. It is inherited from upstream, it is **not built from source by this project**,
and both it and the `.pl` script ship inside the app bundle at `Contents/Resources/`.

That is the largest piece of trust in this app, so it was examined rather than assumed:

| Check | Result |
|---|---|
| Linked libraries (`otool -L`) | Foundation, AppKit, CoreFoundation, ImageIO, JavaScriptCore, UniformTypeIdentifiers, libSystem, libobjc. **No networking framework** |
| Network / shell / URL strings | none |
| JavaScriptCore symbols imported | **none** — linked but unused, no script evaluation |
| Keychain, screen capture, event taps, pasteboard, `URLSession` | **none imported** |
| Private frameworks referenced | `MediaRemote.framework` only — its stated purpose |
| `NSTask` | imported, alongside `ADAPTER_TEST_MODE` and `MEDIAREMOTEADAPTER_TEST_CLIENT_PATH` — consistent with spawning its own test client |

**How it works, and why:** the app runs `/usr/bin/perl` on the bundled
`mediaremote-adapter.pl` (268 lines, readable, no network calls, no shell-outs, no
obfuscation — the one `eval {}` is Perl exception handling). That script uses `DynaLoader` to
`dlopen` the bundled framework and call a symbol in it. The purpose of the indirection is to
reach Apple's private `MediaRemote.framework`, which recent macOS restricts to entitled
processes; running it under an Apple-signed interpreter sidesteps that check.

This is a **deliberate platform workaround, not a hidden one** — but it should be understood
for what it is: the app executes an interpreter against a script that loads an opaque binary.
The script is auditable. The binary is not, beyond the checks in the table above. A binary
cannot be diffed against source, so "clean" here means "no capability for the bad thing was
found", not "proven benign". The way to remove that trust entirely is to build the adapter
from its own source and vendor the result.

## Signing

Local builds are **ad-hoc signed and not notarized**, with a designated requirement of
`identifier "theboringteam.boringnotch"` so that permission grants survive a rebuild. That
requirement is deliberately weak: any binary claiming that identifier satisfies it. It is a
reasonable trade on a personal machine and would not be for a shipped product.

## Entitlements

Sandboxed. `audio-input` (visualiser), `camera` (mirror — currently denied and unused),
`calendars`, `network.client` (the four destinations above), `network.server`, file bookmarks
and user-selected files (the shelf), and Apple Events exceptions scoped to `com.spotify.client`
and `com.apple.Music` only.
