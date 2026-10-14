# ChatFort Privacy Policy

**Effective Date:** March 6, 2026
**Last Updated:** March 6, 2026

## Overview

ChatFort is a private, end-to-end encrypted messaging application designed for activists and organizers. Your privacy is our highest priority. ChatFort is designed so that we have **no access to your data** — we cannot read your messages, see your contacts, or identify you in any way.

## Data Collection

**ChatFort collects no user data.** Specifically:

- **No account creation** — ChatFort does not require an email address, phone number, username, or any identifier to use the app.
- **No user identifiers** — There are no user IDs assigned by the app or shared with any server.
- **No analytics or telemetry** — ChatFort does not collect usage statistics, crash reports, or behavioral data.
- **No tracking** — ChatFort contains no advertising SDKs, tracking pixels, or third-party analytics tools.
- **No cookies** — ChatFort does not use cookies or similar tracking technologies.

## Data Storage

All data is stored **locally on your device only**:

- **Messages** — All messages are end-to-end encrypted. Messages are stored only on your device and the recipient's device. No server retains message content after delivery.
- **Contacts and groups** — Your contact list and group memberships are stored exclusively on your device.
- **Media and files** — Photos, videos, voice messages, and files shared through ChatFort are encrypted and stored on your device.
- **Preferences and settings** — App settings (including language preference, appearance, and Safety Hub configuration) are stored locally on your device.

## Encryption

ChatFort uses end-to-end encryption for all communications:

- All messages are encrypted before leaving your device.
- Encryption keys are negotiated directly between communicating devices.
- The messaging protocol uses **no user identifiers** — there is no permanent identifier that links you to your conversations.
- Message relay servers cannot decrypt message content and do not store messages after delivery.

## Device Permissions

ChatFort requests the following device permissions, each used only for the stated purpose:

| Permission | Purpose |
|---|---|
| **Camera** | Scanning QR codes to connect with contacts; taking photos; video calls |
| **Microphone** | Audio and video calls; recording voice messages |
| **Notifications** | Receiving message and incoming call notifications |
| **Storage** | Sending, receiving, and saving files and media |
| **Bluetooth (BLE)** | Discovering nearby devices for the optional Nearby peer-to-peer feature |
| **Wi-Fi (Wi-Fi Direct)** | Direct device-to-device connections for the optional Nearby feature |
| **Location** | Required by Android for Bluetooth LE scanning and Wi-Fi Direct discovery. **No location data is collected, stored, or transmitted.** |
| **Battery optimization exemption** | Allows the background messaging service to reliably receive messages |
| **Full-screen intent** | Displays incoming voice and video call notifications |
| **Foreground service** | Keeps the messaging service running for reliable message delivery |
| **Biometrics (fingerprint/face)** | Optional app lock authentication, handled entirely by the Android system |

These permissions are never used to collect, transmit, or store data beyond their stated purpose. All permissions are optional.

## Nearby Peer-to-Peer Communication

ChatFort includes an optional Nearby feature for local communication when internet is unavailable:

- Uses Bluetooth Low Energy (BLE) for device discovery and Wi-Fi Direct for data transfer.
- **No data leaves your local network** — all P2P communication stays between nearby devices.
- All nearby messages are encrypted end-to-end (AES-256-GCM).
- No data from P2P sessions is transmitted to any external server.
- No location data is collected or transmitted. The Location permission is required only by the Android operating system to perform Bluetooth and Wi-Fi Direct scanning.

## Third-Party Services

ChatFort does not integrate any third-party services, SDKs, or analytics platforms. The app communicates only with messaging relay servers for message delivery, and these servers:

- Cannot identify users
- Cannot read message content
- Do not retain messages after delivery
- Do not log user activity

## Safety Hub & Emergency Wipe

ChatFort includes a Safety Hub with emergency data wipe features:

- **Emergency code:** An optional self-destruct code that permanently deletes all local data.
- **Quick Settings tile:** An optional "Reset App" tile that can wipe all data from the notification shade.
- **Screen protection:** Prevents app content from appearing in screenshots and the recent apps list.
- All deletions are irreversible and happen entirely on your device.
- No data about emergency wipe usage is transmitted to any server.

## Children's Privacy

ChatFort is not directed at children under 13. We do not knowingly collect any data from anyone, including children. Since the app collects no personal data from any user, no special provisions for children's data are necessary.

## Changes to This Policy

We may update this privacy policy from time to time. Any changes will be reflected in the "Last Updated" date above and in updated versions of the app. As ChatFort collects no user data, changes will primarily reflect new features or clarifications.

## Contact

If you have questions or concerns about this privacy policy:

- **Email:** [chat@inqalaab.chat](mailto:chat@inqalaab.chat)
- **GitHub:** [https://github.com/TheHealer28/ChatFort](https://github.com/TheHealer28/ChatFort)

## Open Source

ChatFort is open source under the AGPLv3 license. You can review the complete source code to verify our privacy practices at the GitHub link above.
