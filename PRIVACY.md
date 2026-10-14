# ChatFort Privacy Policy

**Effective: March 6, 2026**

**Summary:** ChatFort does not collect, store, or have access to any of your messages, contacts, groups, or personal data. Everything stays on your device.

## 1. What data we collect

**None.** ChatFort does not collect any personal data. There are no user accounts, no registration, no phone number or email requirements, and no user identifiers of any kind.

## 2. Messages and files

- All messages and files are end-to-end encrypted.
- Messages are stored only on your device.
- The server relays encrypted messages and cannot read their content.
- Message metadata (who talks to whom) is not accessible to the server due to the protocol design.

## 3. Contacts and profiles

- Your profile (display name) is stored only on your device.
- Your profile is shared only with contacts you choose to connect with.
- There is no central directory of users.

## 4. Server infrastructure

- ChatFort uses its own messaging relay server.
- The server does not store messages after delivery.
- The server does not log IP addresses or connection metadata.
- Server code is open source and auditable.

## 5. Device permissions

ChatFort may request the following device permissions, all of which are optional and used only for the stated purpose:

- **Camera:** Scanning QR codes to connect with contacts, taking photos to send, and video calls.
- **Microphone:** Voice messages and voice/video calls.
- **Notifications:** Alerting you to new messages and incoming calls.
- **Storage:** Sending, receiving, and saving files and media.
- **Bluetooth (BLE):** Discovering nearby devices for the optional Nearby peer-to-peer feature. No Bluetooth data is collected or transmitted to any server.
- **Wi-Fi (Wi-Fi Direct):** Establishing direct device-to-device connections for the optional Nearby feature. No Wi-Fi data is collected or transmitted to any server.
- **Location:** Required by Android to use Bluetooth LE scanning and Wi-Fi Direct peer discovery for the Nearby feature. **No location data is collected, stored, or transmitted.** Location is never used for tracking or geolocation purposes.
- **Battery optimization exemption:** Allows the background messaging service to reliably receive messages. This does not collect any data.
- **Full-screen intent:** Displays incoming voice and video call notifications. This does not collect any data.
- **Foreground service:** Keeps the messaging service running for reliable message delivery in the background. This does not collect any data.
- **Biometrics (fingerprint/face):** Optional app lock authentication. Biometric data is handled entirely by the Android system and is never accessed by ChatFort.

## 6. Nearby peer-to-peer communication

When using the optional Nearby feature:

- Communication happens directly between devices over Bluetooth LE and Wi-Fi Direct.
- No data passes through any external server.
- All nearby messages are encrypted end-to-end (AES-256-GCM).
- No location data is collected or transmitted. The Location permission is required only by the Android operating system to perform Bluetooth and Wi-Fi Direct scanning.

## 7. Analytics and tracking

ChatFort contains no analytics, no tracking, no advertising, and no third-party SDKs that collect data. We do not use Google Analytics, Firebase Analytics, or any similar service.

## 8. Security features

- **App lock:** Optionally lock the app with a passcode or biometrics (fingerprint/face), stored and handled entirely on your device.
- **Emergency code:** An optional self-destruct code that wipes all app data when entered.
- **Quick Settings tile (Android):** An optional "Reset App" tile that can wipe all data from the notification shade.
- **Screen protection:** Prevents app content from appearing in screenshots and the recent apps list.

## 9. Data deletion

You can delete all your data at any time by:

- Using the emergency code feature.
- Using the Quick Settings "Reset App" tile (Android).
- Deleting the database from Settings.
- Uninstalling the app (all data is stored locally and is removed with the app).

## 10. Children's privacy

ChatFort is not directed at children under 13. We do not knowingly collect any data from anyone, including children.

## 11. Changes to this policy

We may update this privacy policy from time to time. Any changes will be reflected in the app and on this page with an updated effective date.

## 12. Open source

ChatFort is open source under the AGPLv3 license. You can review the complete source code at [https://github.com/TheHealer28/ChatFort](https://github.com/TheHealer28/ChatFort).

## 13. Contact

If you have questions about this privacy policy, you can reach us at [chat@inqalaab.chat](mailto:chat@inqalaab.chat).
