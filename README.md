# Telemic

Use one Mac's microphone as another Mac's microphone, over your Tailnet or local network.

The receiving Mac gets a virtual input device called **Telemic**. Audio goes straight into
that device and is never *played* by any app, so remote-desktop and screen-capture tools that
forward the host's sound (UU Remote, etc.) don't send your own voice back to you as an echo.

## Why

Remote-desktop tools forward the host's *sound* to you, but rarely your *microphone* to the
host. Routing your mic in through a virtual "speaker" device (BlackHole, SonoBus…) gets played
on the host and is captured right back to you as an echo. Telemic feeds a dedicated virtual
microphone directly, so there is nothing to echo — dictation, calls and voice input on the host
just work.

## Install

1. Download `Telemic-x.y.z.dmg` from [Releases](../../releases) and drag **Telemic** to
   Applications on every Mac. Requires macOS 13 or later (Apple silicon or Intel).
2. Open it — it lives in the menu bar. Signed releases update themselves (⋯ → Check for Updates…).

## Use

**On the Mac that should *receive* (gets the Telemic microphone)**

1. Choose **Receive**.
2. Click **Install driver** (administrator password; restarts the audio service, no reboot).
3. If Telemic isn't the default input, click **Fix**, or pick Telemic in a specific app.
4. Note the address shown (Tailnet IP if available, otherwise LAN IP); **Copy** puts it on the clipboard.

**On each Mac that should *send* its microphone**

1. Choose **Send**.
2. Pick the receiver from **Nearby receivers**, or enter its address.
3. Turn the microphone on and allow microphone access.

**Back on the receiver**, allow the new sender (in the panel or the notification). Compare the
fingerprint shown on both Macs if you want to be sure it's yours.

With two or more senders the receiver can listen to **One** (click a sender to choose) or **Mix all**.
Everything else is in the **⋯** menu:

| Role | In ⋯ / right-click | Default |
|---|---|---|
| Receiver | Only accept devices on the Tailnet | Off |
| Receiver | Driver: reinstall / uninstall | — |
| Receiver | Right-click a sender: volume (50–200%), rename, fingerprint, remove | — |
| Sender | Receiver: recent, nearby, or another address | — |
| Sender | Input device | System default |
| Sender | Voice enhancement (Apple noise/echo processing) | Off |
| Sender | Shortcuts: toggle mic, hold to talk | None |
| Both | Open at login, switch role, copy diagnostics | Off |

When the two Macs run different Telemic versions, an orange note says so; update both.

## How it works

```
sender Mac                                  receiver Mac
mic → Opus 32 kbps → ChaCha20-Poly1305 ─UDP 47810─▶ jitter buffer → decode → playout
      (each packet also carries the                 │ (loss rebuilt from redundancy,
       previous two frames)                         │  Opus PLC for longer gaps,
                                                    │  ±0.1% drift correction)
                                                    └─ 127.0.0.1:47811 ─▶ Telemic driver ─▶ apps
```

- **Pairing**: each Mac has an X25519 key. The audio key is derived per session; the receiver
  only accepts keys the user allowed, and the sender pins the receiver's key (warns if it changes).
- **Loss**: tested at ~10% random loss → <1% after recovery. The receiver shows
  "loss → after recovery" per sender.
- **Latency**: ~40–60 ms of buffering plus the network. Dictation doesn't need less.

Details, decisions and the App Store analysis: [docs/DESIGN.md](docs/DESIGN.md).

## Build

Needs only the Xcode Command Line Tools (no Xcode project).

```bash
./build-app.sh     # build/Telemic.app (universal), driver + Sparkle bundled, ad-hoc signed
./test.sh          # unit tests + end-to-end self-test (never touches the live driver)
./make-dmg.sh      # dist/Telemic-<version>.dmg
./release.sh       # Developer ID signed + notarized DMG (see the script for one-time setup)
```

**Releasing**: publish a GitHub release with a tag like `v0.7.1`. The
[Release workflow](.github/workflows/release.yml) sets the version from the tag, runs
`release.sh` (build, tests, sign, notarize, staple, sign the Sparkle feed) and attaches
`Telemic-0.7.1.dmg` and `appcast.xml` to the release; installed copies pick it up within a day,
or right away via **⋯ → Check for Updates…**. The secrets it needs are listed at the top of the workflow.

`build-app.sh` fetches the pinned [Sparkle](https://sparkle-project.org) release into `Vendor/`
(hash-checked, not committed). Only Developer ID signed releases check for updates; self-built
copies never replace themselves.

Layout: `App/` (menu bar app, SwiftUI), `Driver/` (Core Audio AudioServerPlugIn, C),
`Tests/Unit/`, `Tools/telemic-feed` (push speech/tones into the driver, meter its input),
`Tools/icon` (draws the app icon).

## Uninstall

Receiver: **⋯ → Driver → Uninstall**, then delete the app. Settings live in
`~/Library/Preferences/com.peakviber.telemic.plist`; the device key is in `~/Library/Application Support/Telemic/`
(ad-hoc builds) or in the login Keychain as "Telemic device key" (signed releases).

## Formerly RemoteMic

Up to 0.6.1 the app was called RemoteMic (`com.remotemic.app`). On first launch Telemic carries
over its settings, approved senders and device key, quits and trashes `RemoteMic.app`, and
replaces the RemoteMic driver when you install the Telemic one. It still talks to 0.6.x peers.
RemoteMic 0.6.1 can't update itself to Telemic (different app ID): install Telemic once by hand.

## License

MIT — see [LICENSE](LICENSE).
