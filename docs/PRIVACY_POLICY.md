# Inqalaab Privacy Policy

**Effective Date:** March 2, 2026
**Last Updated:** March 6, 2026

## Overview

Inqalaab is a private, end-to-end encrypted messaging application built on the SimpleX protocol. Your privacy is our highest priority. Inqalaab is designed so that we have **no access to your data** — we cannot read your messages, see your contacts, or identify you in any way.

## Data Collection

**Inqalaab collects no user data.** Specifically:

- **No account creation** — Inqalaab does not require an email address, phone number, username, or any identifier to use the app.
- **No user identifiers** — There are no user IDs assigned by the app or shared with any server.
- **No analytics or telemetry** — Inqalaab does not collect usage statistics, crash reports, or behavioral data.
- **No tracking** — Inqalaab contains no advertising SDKs, tracking pixels, or third-party analytics tools.
- **No cookies** — Inqalaab does not use cookies or similar tracking technologies.

## Data Storage

All data is stored **locally on your device only**:

- **Messages** — All messages are end-to-end encrypted using the SimpleX protocol. Messages are stored only on your device and the recipient's device. No server retains message content after delivery.
- **Contacts and groups** — Your contact list and group memberships are stored exclusively on your device.
- **Media and files** — Photos, videos, voice messages, and files shared through Inqalaab are encrypted and stored on your device.
- **Preferences and settings** — App settings (including language preference, appearance, Safety Hub configuration, Lockdown Mode state, and emergency contact selections) are stored locally using iOS standard preferences.
- **Emergency contacts** — Your selection of emergency contacts is stored locally on your device as a list of contact identifiers. This data never leaves your device.

## Encryption

Inqalaab uses the SimpleX protocol for end-to-end encryption:

- All messages are encrypted before leaving your device.
- Encryption keys are negotiated directly between communicating devices.
- The SimpleX protocol uses **no user identifiers** — unlike other messaging apps, there is no permanent identifier that links you to your conversations.
- Message relay servers cannot decrypt message content and do not store messages after delivery.

## Nearby Peer-to-Peer Communication

Inqalaab includes a Nearby P2P feature for local communication when internet is unavailable:

- Uses Apple's Multipeer Connectivity framework over local Wi-Fi and Bluetooth.
- **No data leaves your local network** — all P2P communication stays between nearby devices.
- No data from P2P sessions is transmitted to any external server.

## Device Permissions

Inqalaab requests the following device permissions, each used only for the stated purpose:

| Permission | Purpose |
|---|---|
| **Camera** | Scanning QR codes to connect with contacts; video calls |
| **Microphone** | Audio and video calls; recording voice messages |
| **Photo Library** | Saving and sharing photos and media |
| **Face ID / Touch ID** | Optional local app authentication |
| **Bluetooth** | Nearby P2P communication for offline messaging |
| **Local Network** | Nearby P2P communication; desktop app pairing |
| **Notifications** | Receiving message notifications |

These permissions are never used to collect, transmit, or store data beyond their stated purpose.

## Third-Party Services

Inqalaab does not integrate any third-party services, SDKs, or analytics platforms. The app communicates only with SimpleX protocol relay servers for message delivery, and these servers:

- Cannot identify users
- Cannot read message content
- Do not retain messages after delivery
- Do not log user activity

## Safety Hub & Security Features

Inqalaab includes a Safety Hub (Protection tab) with several security features. All of these operate entirely on your device:

### Panic Mode
- When triggered (via shake gesture), Panic Mode permanently deletes all local data including messages, contacts, files, and settings.
- This deletion is irreversible and happens entirely on your device.
- No data about Panic Mode usage is transmitted to any server.

### Deadman's Switch
- If enabled, automatically triggers data wipe if the app is not opened within a user-configured time period.
- The last-opened timestamp is stored locally on your device only.

### Lockdown Mode
- Applies maximum privacy settings (hides previews, enables incognito mode, activates screen protection) with one tap.
- All settings are stored and restored locally. No data is transmitted.

### Emergency Contacts & Alerts
- You can mark existing contacts as "emergency contacts" for one-tap check-in messaging.
- Emergency contact selections are stored locally on your device as contact identifiers.
- Check-in and alert messages are sent through the same end-to-end encrypted SimpleX protocol channels as regular messages.
- No special data about emergency contacts or alerts is transmitted to any server beyond the encrypted messages themselves.

## Children's Privacy

Inqalaab does not knowingly collect any data from children under 13. Since the app collects no personal data from any user, no special provisions for children's data are necessary.

## Changes to This Policy

We may update this privacy policy from time to time. Any changes will be reflected in the "Last Updated" date above and in updated versions of the app. As Inqalaab collects no user data, changes will primarily reflect new features or clarifications.

## Contact

If you have questions or concerns about this privacy policy:

- **GitHub:** [https://github.com/TheHealer28/Inqalaab](https://github.com/TheHealer28/Inqalaab)
- **Email:** Open an issue on our GitHub repository

## Open Source

Inqalaab is open source under the AGPLv3 license. You can review the complete source code to verify our privacy practices at the GitHub link above.
