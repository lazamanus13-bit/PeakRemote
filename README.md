# Peak Remote

A native iOS app (SwiftUI + CoreBluetooth) for controlling a Puffco Peak Pro over Bluetooth.

**What it does**
- Finds and connects to your Peak, then pairs and unlocks it (Lorax SHA-256 handshake)
- Live temperature dial, operating state, session countdown, battery
- Start heat, Boost, Stop
- View the 4 heat profiles, select the active one, and edit temperature and duration
- Stealth mode, lantern mode, LED brightness
- Chamber type, lifetime dab count, model, firmware, serial
- °F / °C toggle
- Debug log (ladybug icon) with a Share button, for troubleshooting

The protocol is ported from two MIT-licensed community projects: [puffco-py](https://github.com/SoyMilkIsOk/puffco-py) and [PuffcoBLE](https://github.com/Fr0st3h/PuffcoBLE). This project isn't affiliated with Puff Corp.

---

## 1. Build it

You need a Mac with Xcode 15 or newer and an iPhone or iPad on iOS 16 or later. The Simulator has no Bluetooth, so you have to use a real phone.

```bash
brew install xcodegen          # one-time
cd PeakRemote
xcodegen generate              # creates PeakRemote.xcodeproj
open PeakRemote.xcodeproj
```

In Xcode:

1. Select the **PeakRemote** target and open **Signing & Capabilities**.
2. Choose your **Team**. A free Apple ID works.
3. Change the **Bundle Identifier** to something unique, e.g. `com.yourname.PeakRemote`.
4. Plug in your iPhone and select it as the run destination at the top of the window.
5. Press **⌘R**.

First run on a new iPhone:
- Turn on **Developer Mode**: Settings → Privacy & Security → Developer Mode. The phone restarts.
- If iOS says the developer isn't trusted, go to Settings → General → VPN & Device Management, tap your Apple ID, and choose Trust.

> **Free Apple ID:** the app stops opening after 7 days. Press ⌘R again from Xcode to reinstall it. A paid developer account ($99/yr) extends that to a year.

**Run the protocol tests** with **⌘U**. These can run on the Simulator. They check the Swift auth token, packet layout and decoders against values generated from the Python reference libraries.

### No XcodeGen? Set it up by hand
1. In Xcode, choose File → New → Project → iOS **App**. Name it `PeakRemote`, select SwiftUI as the interface, and pick a location.
2. Delete the generated `ContentView.swift` and `PeakRemoteApp.swift`.
3. Drag the `PeakRemote/App`, `BLE`, `Model`, `Protocol` and `Views` folders into the project, and replace its `Assets.xcassets` with this one. Check "Copy items if needed."
4. Target → Info tab: add **Privacy – Bluetooth Always Usage Description** with any text.
5. Target → General: set Minimum Deployments to **iOS 16.0**.
6. Optional: add a Unit Testing Bundle target and drop in `PeakRemoteTests/LoraxTests.swift`.

## 2. First connection

1. **Force-quit the official Puffco app.** The device only talks to one app at a time.
2. Wake your Peak. It should appear under its name; turn on **Show all devices** if it doesn't.
3. Tap it. If iOS shows a Bluetooth pairing request, accept it.
4. The status goes Connecting → Pairing → Unlocking → Connected.

If the connection drops, the app reconnects automatically when the Peak comes back in range. Next time you open the app, your last device appears at the top of the list.

## 3. If something doesn't work

The two source libraries disagree in a few places, and this build hasn't been tested against real hardware yet. These are the most likely trouble spots:

| Symptom | Likely cause | Where to fix |
|---|---|---|
| Fails at "Unlocking device…" | The reply's 3rd byte isn't a status code on your firmware. | `readPath` in `PuffcoController.swift`: return `reply.payload` regardless of status. |
| Battery or dab count shows "—" | Different path on your firmware. The app tries both known paths. | `LoraxPath` in `Lorax.swift` |
| Profile duration saves wrong | The firmware stores time as a different type. The app mirrors whatever type it read. | `saveProfile` in `PuffcoController.swift` |
| "Doesn't expose the Lorax service" | Older pre-Lorax firmware. | Update the Peak's firmware in the Puffco app. |

Open the **debug log** (ladybug icon), tap Copy, and paste the log into chat. It shows each step of the handshake and every read and write, which makes most of these quick to fix.

## Project layout

```
PeakRemote/
  App/PeakRemoteApp.swift        entry point and root navigation
  Protocol/Lorax.swift           UUIDs, opcodes, packet framing, auth token, decoders
  Model/Models.swift             device state, profiles, labels
  BLE/PuffcoController.swift     CoreBluetooth: scan, connect, pair, unlock, poll, commands
  Views/                         ScanView, DeviceView, ProfileEditView, LogView
PeakRemoteTests/LoraxTests.swift protocol unit tests
project.yml                      XcodeGen spec
```

## Notes
- This app is for personal use. Apple's App Store rules on vaping-related apps, plus Puffco's trademarks, mean it probably wouldn't be approved for public release.
- Power off and factory reset are deliberately left out.
