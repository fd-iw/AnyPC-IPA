# AnyPC for iPhone

Control your Windows PC from your iPhone. Works with the **AnyPC Desktop** app
([fd-iw/AnyPC-Desktop-App](https://github.com/fd-iw/AnyPC-Desktop-App)) running on the PC.

Built for **iPhone SE (1st generation) on iOS 15** and works on any iPhone with iOS 15 or later.

## Features

- **Live screen** of the PC with the mouse cursor, plus a picker when the PC has several monitors
- **Trackpad mode**:
  - drag to move the pointer
  - tap to click
  - two-finger tap to right-click
  - hold, then drag, to drag
  - two-finger drag to scroll
  - pinch to zoom
- **Touch mode**: tap exactly where you want to click
- **Keyboard**:
  - the iOS keyboard types on the PC
  - a key bar adds Ctrl, Alt, Shift, Win, Esc, Tab, the arrows, Del, Home/End, PgUp/PgDn, F1–F12 and PrtSc
  - tap Ctrl, then C, to send Ctrl+C
- **Files**:
  - browse the PC's drives
  - download files to the iPhone, then open or share them
  - send photos, videos or files to the PC
- **Power and media**:
  - lock, sleep, sign out, restart, shut down
  - volume, mute, play/pause, next/previous track
  - show desktop, Task Manager
- Secure pairing with a QR code or a 6-digit PIN. The connection is TLS-encrypted, with the PC's certificate pinned.

## Get the IPA

1. Open this repo's **Actions** tab, then **Build IPA**, then the latest green run.
2. Download the **AnyPC-IPA** artifact. It's a zip; unzip it to get `AnyPC.ipa`.
   Tagged versions (`v*`) are also attached to **Releases**.

The IPA is **unsigned**. Apple only lets an iPhone run apps that are signed for it, so you sign it
with your own Apple ID while installing it. A free Apple ID is enough.

## Install on your iPhone SE

### Option A: Sideloadly (Windows or Mac, easiest)

1. Install [iTunes](https://www.apple.com/itunes/) (the version *not* from the Microsoft Store) and [Sideloadly](https://sideloadly.io) on your computer.
2. Connect the iPhone with a USB cable, unlock it and tap **Trust This Computer**.
3. Drag `AnyPC.ipa` into Sideloadly, enter your Apple ID and click **Start**.
4. On the iPhone, open **Settings › General › VPN & Device Management**, tap your Apple ID and then **Trust**.
5. Open AnyPC. When iOS asks to find devices on your local network, tap **OK**.

With a free Apple ID, the app has to be **re-signed every 7 days**. Sideloadly can refresh it
automatically over Wi-Fi. A paid Apple Developer account extends this to 1 year.

### Option B: AltStore

Install [AltStore](https://altstore.io) with AltServer, open the IPA in AltStore on the iPhone
(**My Apps › +**), and keep AltServer running on your computer so AltStore can refresh the app
every 7 days.

## First connection

1. Install and start **AnyPC Desktop** on the PC. It shows a QR code and a PIN.
2. Put the iPhone on the **same Wi-Fi** as the PC.
3. In AnyPC on the iPhone, either:
   - tap **Scan QR code** and point the camera at the PC screen, or
   - tap your PC under **Nearby** and type the PIN.
4. You're in. Next time, just tap the PC under **My PCs**; no PIN is needed.

Toolbar, left to right:

- keyboard
- control mode (tap to switch; long-press for help)
- monitors (only when the PC has several)
- files
- power
- settings
- disconnect

## Troubleshooting

| Problem | Fix |
|---------|-----|
| The PC never shows up under *Nearby* | Check **Settings › AnyPC › Local Network** is on, and both devices are on the same Wi-Fi (not a guest network). Or use **Add PC by IP address**. |
| "Can't connect" | Make sure AnyPC is running on the PC (look for the tray icon), and that Windows has the Wi-Fi network set to **Private**. |
| "Security check failed" | The PC's AnyPC was reinstalled, so it has a new certificate. Swipe the PC away in *My PCs* and pair again. |
| The app won't open ("Untrusted developer") | **Settings › General › VPN & Device Management**, then trust your Apple ID. |
| The app stopped opening after a week | Re-sign or refresh it with Sideloadly or AltStore (free Apple ID limit). |
| Choppy picture | In **Settings**, lower *Quality*, *Resolution* or *Frame rate*. |

## Build from source

You need a Mac with Xcode 15 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate          # creates AnyPC.xcodeproj from project.yml
open AnyPC.xcodeproj       # set your Team to run on a device
```

To build an unsigned IPA the same way CI does, see `.github/workflows/build-ipa.yml`.

Code layout:

- `AnyPC/Net`: the WebSocket connection with TLS pinning (`PCConnection`), Bonjour discovery, and the wire format
- `AnyPC/Remote`: the screen view and gestures, the keyboard bridge and its key bar, and the remote screen
- `AnyPC/Files`: the file browser, pickers and share sheet
- `AnyPC/Views`: home, pairing, QR scanner, system actions and settings
- `docs/PROTOCOL.md`: the protocol shared with the desktop app
