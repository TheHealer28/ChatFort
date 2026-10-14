# Inqalaab — انقلاب

**Secure messaging for activists and organizers in Pakistan & South Asia.**

Inqalaab is a privacy-first messaging app built for people who need their communications to stay private — journalists, human rights defenders, organizers, and ordinary citizens living under surveillance. It runs on the [SimpleX protocol](https://github.com/simplex-chat/simplex-chat), which means **no phone number, no user ID, no metadata** — the server never knows who is talking to whom.

> *"Inqalaab"* (انقلاب) means *revolution* in Urdu.

---

## Why Inqalaab?

Most messaging apps require a phone number or email to sign up. That alone makes you identifiable. SimpleX solved the identity problem at the protocol level — Inqalaab takes that foundation and adds features specifically designed for high-risk environments:

- **Panic Mode** — Shake your device to instantly and permanently wipe all data. Configurable shake threshold (3–10 shakes). No confirmation dialog — because in an emergency, every second counts.
- **Emergency Wipe** — One-tap data destruction from the Safety Hub. Deletes messages, contacts, profile, database, keychain credentials, and reinitializes a clean state.
- **Safety Hub** — A single dashboard to check and toggle all security settings: App Lock, Screen Protection, Private Notifications, and Link Preview blocking.
- **Nearby P2P Messaging** — Communicate with people around you without any internet connection using peer-to-peer discovery (MultipeerConnectivity on iOS). No servers involved.
- **Urdu / English Toggle** — Switch the entire app language instantly from Settings, no app restart needed.
- **Independent Servers** — Connects through Inqalaab-operated relay servers by default, separate from the main SimpleX infrastructure.
- **No Preset Contacts** — Ships clean. No default "team" or "status" contacts are added to your chat list.
- **Auto-Generated QR Code** — Your contact address QR code is displayed on the main screen for quick in-person sharing.

---

## Features

| Feature | Description |
|---|---|
| No identifiers | No phone number, email, or username required |
| End-to-end encryption | Double Ratchet protocol (same family as Signal) |
| No metadata | Servers cannot see who talks to whom |
| Panic Mode | Shake-to-wipe emergency data destruction |
| Safety Hub | Security dashboard with quick toggles |
| Nearby P2P | Offline device-to-device messaging |
| Bilingual | Urdu ↔ English in-app language switch |
| App Lock | Biometric or passcode protection |
| Screen Protection | Hides app content in the app switcher |
| Private Notifications | Notifications without message previews |
| Open Source | AGPLv3 — fully auditable |

---

## Screenshots

*Coming soon.*

---

## Building from Source

### Prerequisites

- macOS with Xcode 15+
- iOS 16+ deployment target
- The SimpleX Chat Haskell libraries (pre-built, included in `apps/ios/Libraries/`)

### iOS

```bash
git clone https://github.com/YourUsername/Inqalaab.git
cd Inqalaab
open apps/ios/SimpleX.xcodeproj
```

Select the **SimpleX (iOS)** scheme, choose your device or simulator, and build.

### Android

Android version is under development. See the feature reference document in the repo for parity targets.

---

## Project Structure (Inqalaab-specific files)

```
apps/ios/Shared/
├── InqalaabServers.swift          # Server configuration & preset contact cleanup
├── Views/
│   ├── InqalaabTabView.swift      # Root tab bar with locale override
│   ├── SafetyHub/
│   │   ├── SafetyHubView.swift    # Security dashboard
│   │   ├── PanicModeView.swift    # Panic mode configuration UI
│   │   ├── PanicWipeManager.swift # Shared emergency wipe logic
│   │   └── InqalaabShakeDetector.swift  # Shake gesture detection
│   └── Nearby/
│       ├── NearbyModel.swift      # P2P state management
│       ├── NearbyService.swift    # MultipeerConnectivity bridge
│       ├── NearbyStore.swift      # Local message persistence
│       └── NearbyTypes.swift      # Data models
```

---

## Contributing

Contributions are welcome. If you're working on security features for at-risk users, please reach out.

Before submitting a PR:
- Test on a real device (shake detection, Nearby P2P, etc.)
- Ensure no `print("Inqalaab ...")` debug statements are left in release code
- Follow the existing code patterns

---

## Attribution & License

Inqalaab is a modified version of [SimpleX Chat](https://github.com/simplex-chat/simplex-chat), an open-source messaging platform created by SimpleX Chat Ltd.

**License:** [GNU Affero General Public License v3 (AGPLv3)](./LICENSE)

All modifications are copyright © 2025–2026 the Inqalaab contributors and are released under the same AGPLv3 license.

Per the SimpleX Chat [trademark policy](./docs/TRADEMARK.md), the SimpleX name and logo are trademarks of SimpleX Chat Ltd and are not used in this project's branding. Inqalaab is compatible with the SimpleX network but is not affiliated with or endorsed by SimpleX Chat Ltd.

---

## Security

If you find a security vulnerability, please report it privately. Do not open a public issue.

---

*Built with purpose. Stay safe.*
