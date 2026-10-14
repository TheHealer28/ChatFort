# ChatFort

**Private messaging for activists, organisers and communities, in English and Urdu (اردو), that keeps
working when the internet doesn't.**

ChatFort is an end-to-end encrypted messenger for people whose communications need to stay private:
human rights defenders, journalists, organisers and anyone living under surveillance. You don't need a
phone number, email or username. ChatFort runs its own servers. When the internet is shut down, nearby
phones can still carry messages to each other over Bluetooth.

The iOS app is on the [App Store](https://apps.apple.com/app/id6759920785).

---

## What ChatFort does

### Messaging and calls
- **No identifiers:** no phone number, email or username. You connect by scanning a QR code or opening
  a link, in person or through a trusted channel.
- **End-to-end encryption** for messages, photos, files and voice messages.
- **Voice and video calls:** encrypted calls and group calls, with picture-in-picture. Calls recover
  from short network drops.
- **Own servers:** messages and files go through ChatFort's own relay servers, and push notifications
  through ChatFort's own notification server. The server list comes from ChatFort's own endpoint, with
  no third-party analytics.
- **QR address:** every profile gets a QR code that people can scan to connect to it.

### Crowd mesh: messaging without internet
- **Phone to phone over Bluetooth:** messages hop from phone to phone, up to 7 phones away, with no
  internet and no servers. iPhones and Android phones running ChatFort talk to each other.
- **Everyone, Teams and People:**
  - **Everyone** is a public channel for everyone nearby.
  - **Teams** are joined by scanning a team code face to face. Only team members can read them.
  - **People** are private one-to-one chats.
- **Your ChatFort contacts, offline:** contacts you already have show up in the Crowd mesh. Send them
  texts, photos and voice notes over Bluetooth, with delivery ticks.
- **Store and forward:** messages wait (up to 24 hours) and are delivered when the person comes into
  range.
- **Nickname only:** you appear under a nickname you choose, never your profile name.
- **Opt-in:** the Crowd mesh only runs after you start it in the **Nearby** tab, and you can stop it at
  any time.
- **Nearby iPhones:** a separate option in the Nearby tab chats directly with iPhones next to you.

### Protection
- **Safety Hub (Protection tab):** a security score, network status, and one-tap security toggles
  (App Lock, screen protection, private notifications, link previews).
- **Panic Mode:** shake the phone a set number of times to wipe all ChatFort data instantly.
- **Emergency Wipe:** one tap deletes messages, contacts, profiles, the database and saved keys.
- **Deadman's switch:** wipes the app automatically if it isn't opened within a time you choose.
- **Lockdown Mode:** one tap switches five privacy settings to their strictest values, and restores them
  afterwards.
- **Emergency contacts and alerts:** send "I'm safe", "Need assistance" or an emergency alert to your
  trusted contacts with one tap.

### Language
- **English and Urdu:** switch inside the app, with no restart.

---

## Building the iOS app

### Requirements
- A Mac with Apple silicon and **Xcode 27.0**.
- [Nix](https://nixos.org/download/), to build ChatFort's core libraries. They are not checked in, and
  the build takes a few hours the first time.
- An Apple Developer account, to sign the app with your own team and bundle ID.

### Steps

```bash
git clone https://github.com/TheHealer28/Inqalaab.git
cd Inqalaab

# 1. Build the core library for iOS devices (Haskell, via Nix)
nix build ".#packages.aarch64-darwin.\"aarch64-darwin-ios:lib:inqalaab\""

# 2. Copy the built libraries into apps/ios/Libraries
scripts/ios/prepare.sh

# 3. Open the project
open apps/ios/SimpleX.xcodeproj
```

In Xcode, choose the **Inqalaab (iOS)** scheme, set your own team and bundle ID under Signing &
Capabilities, and build.

Some internal names (the repository, the Xcode project and schemes, the bundle ID and the core
library) still use the project's earlier name. They have to match the build files, so they weren't
renamed.

### Android
The Android app is on the [`android-updates`](https://github.com/TheHealer28/Inqalaab/tree/android-updates)
branch, under `apps/multiplatform`.

---

## Where things are

```
apps/ios/Shared/
├── CrowdMesh/            # Crowd mesh: Bluetooth link layer, routing, offline contacts, screens
├── Nearby/               # Nearby iPhones (MultipeerConnectivity)
├── Views/
│   ├── SafetyHub/        # Safety Hub, Panic Mode, Emergency Wipe, Lockdown, emergency contacts, alerts
│   ├── Nearby/           # Nearby tab
│   └── Call/             # Voice, video and group calls
src/                      # Core library (Haskell)
```

---

## Privacy

ChatFort collects no data and has no analytics or advertising. See the
[privacy policy](docs/PRIVACY_POLICY.md).

## Security

Please report vulnerabilities privately to **chat@inqalaab.chat**. Don't open a public issue.

## Contributing

Contributions are welcome, especially from people working on safety for at-risk users. Please test on
real devices: shake detection, Bluetooth and the camera don't work in the Simulator.

## License

ChatFort is free software under the [GNU Affero General Public License v3](LICENSE) (AGPLv3).

ChatFort is a modified version of an open-source messenger released under the AGPLv3. The original
copyright notices are kept in the source files.
