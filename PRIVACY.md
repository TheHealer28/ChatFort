# ChatFort Privacy Policy

**Effective date:** March 2, 2026
**Last updated:** October 21, 2026

## Summary

ChatFort is a private messenger for iPhone and Android. You don't need a phone number, an email
address or an account. Messages and calls are end-to-end encrypted, and your messages, contacts and
settings are kept on your own phone. We can't read your messages or see who you talk to. The app
contains no analytics, advertising or tracking.

## 1. What we collect

- **No account data.** ChatFort doesn't ask for a phone number, email address or username. It doesn't
  assign you a user ID.
- **No analytics or tracking.** There is no usage tracking, crash reporting, advertising, tracking SDKs
  or cookies.
- **What you choose to email us.** If you write to us, including when you report a crowd mesh message
  (section 7), we receive what you send and your email address. We use it only to reply and to improve
  safety, for example the word filter. We don't share it, except to report child sexual abuse material
  to the authorities (see the Child Safety Standards) or when the law requires it. We delete it on
  request.

## 2. Messages, calls and files

- Messages, photos, files and voice messages are encrypted on your phone before they're sent.
  Encryption keys are agreed directly between the phones in a conversation.
- ChatFort uses an open-source messaging protocol with no user identifiers, so no permanent ID links you
  to your conversations.
- Messages and files pass through ChatFort's servers, which can't read them. Messages are deleted once
  they're delivered, and files are deleted when they expire.
- Your messages, contacts, groups and profile are stored only on your device. Your profile is shared
  only with the contacts you connect with, and there is no directory of users.
- Audio and video calls are end-to-end encrypted. They connect directly between the two phones when
  they can; otherwise they pass through ChatFort's own relay servers, which can't hear or see the call.
- To set up a call, your phone contacts connection servers (ChatFort's, and Cloudflare's public STUN
  server), which see your IP address.
- On a direct call, the other person's phone sees your IP address. You can choose to always use the
  relay in the call settings, so the other person never sees it.

## 3. ChatFort's servers

- ChatFort runs its own servers for messages, files, notifications and calls. They can't read message
  content or hear calls, hold no user accounts or IDs, and don't keep messages after delivery.
- Our messaging and call servers don't log your IP address or who you talk to.
- The app downloads the current list of ChatFort's servers from our own web service, and, when you make
  or receive a call, the list of call servers with a temporary login. As with any web request, that
  service sees your IP address. Nothing else about you is sent. The service runs on Cloudflare, which may
  keep standard request logs, such as IP addresses, for a few days.
- The server software is open source.

## 4. Notifications

- Notifications are optional. On iPhone, if you turn on instant or periodic notifications, the app
  registers a device token with ChatFort's notification server. That server uses Apple's push service
  to wake your phone when a message arrives.
- The notification server sees the token, but not your messages or contacts.
- Turning notifications off removes the token. You can hide message previews in Settings.
- On Android, ChatFort uses no push service and registers no token: the app checks for new messages
  itself, with a background service (shown as an ongoing notification) or periodically.

## 5. Crowd mesh (messaging without internet)

- The crowd mesh is optional. It runs only after you start it in the Nearby tab, and you can stop it at
  any time.
- Phones running ChatFort connect directly over Bluetooth Low Energy and pass messages on, up to 7 phones
  away. No server is involved.
- People nearby see the nickname you choose, or a random one, never your ChatFort profile name. Your crowd mesh identity
  changes regularly and isn't linked to your profile.
- **Everyone** is public: anyone nearby who runs the crowd mesh can read it. Private chats and team chats
  are end-to-end encrypted.
- Your phone also passes on other people's messages. It can't read the private and team messages it
  passes on.
- To let your ChatFort contacts reach you offline, the app sends them a hidden link message through your
  normal encrypted chat.
- While the crowd mesh is on, the app keeps using Bluetooth in the background so that messages can still
  arrive.
- Crowd mesh messages, the people you've blocked and your agreement to the crowd mesh rules stay on your
  device. The emergency wipe erases them.

## 6. Nearby

The optional Nearby feature lets you chat directly with phones next to you. No server is involved,
and no location data is collected.

- **iPhone:** uses Multipeer Connectivity (Wi-Fi and Bluetooth); messages are encrypted between the
  phones.
- **Android:** Nearby rooms use Wi-Fi Direct, and Bluetooth to find rooms. Nearby room messages aren't
  end-to-end encrypted: anyone nearby with the right tools can read them. The app shows this warning
  too.

## 7. Reporting and blocking

- In the crowd mesh, long-press a message to report it or to block the sender. Blocking happens only on
  your phone.
- **Reporting opens an email in your own email app,** addressed to us. It contains:
  - the message
  - the sender's nickname
  - a short sender ID
  - the time
  - your app version and phone system version (for example iOS 27 or Android 16)

  You can read and change it before sending, and nothing is sent unless you send it. We receive your
  email address with it.
- The crowd mesh has no accounts and no servers, so we can't identify anyone or delete messages from
  other people's phones. We use reports to help the person who reported and to improve the word filter.
- The offensive-word filter runs on your phone. Nothing about it is sent to us.

## 8. Safety features

All of these run on your device and send nothing to us:

- **App lock and screen protection:** the app lock uses a local passcode or biometrics (Face ID, Touch
  ID or fingerprint).
- **Panic Mode (iPhone):** shake the phone to wipe all ChatFort data.
- **Emergency Wipe**, and an optional **self-destruct code**.
- **Deadman's Switch (iPhone):** wipes the app if it isn't opened within a time you choose. The last-opened time is
  stored only on your device.
- **Lockdown Mode (iPhone):** one tap applies the strictest privacy settings, and restores them later.
- **Emergency contacts and alerts:** your choice of contacts is stored on your device. Check-ins and
  alerts are sent as normal end-to-end encrypted messages.
- **Quick Settings "Reset App" tile (Android):** wipes all data from the notification shade.

## 9. Device permissions

Each permission is optional and is used only for its stated purpose.

| Permission | Purpose |
|---|---|
| Camera | Scanning QR codes, taking photos to send, video calls |
| Microphone | Calls, voice messages and voice notes |
| Photos | Sharing and saving photos |
| Face ID, Touch ID or fingerprint | Optional app lock |
| Bluetooth | The crowd mesh and Nearby |
| Local Network (iPhone) | Nearby, and pairing with a desktop |
| Nearby devices (Android 12 and later) | Finding phones for the crowd mesh and Nearby rooms (Bluetooth and Wi-Fi Direct) |
| Notifications | Message notifications |
| Battery optimisation exemption (Android, optional) | Keeps messages and the crowd mesh running in the background |
| Location (older Android versions) | Required by those versions to scan for Bluetooth and Wi-Fi Direct devices. ChatFort doesn't use it to locate you. |

## 10. Deleting your data

Your data is on your device, so you control it. You can delete everything with:

- Emergency Wipe, or Panic Mode (iPhone)
- the self-destruct code
- deleting the database in Settings
- uninstalling the app

To have anything you emailed us deleted, ask us.

## 11. Children

ChatFort is for people aged 18 and over (see the Terms of Use). It collects no personal data from anyone.
How we handle child safety reports is set out in the Child Safety Standards in our Community Guidelines.

## 12. Changes to this policy

When this policy changes, the new version appears here with a new "Last updated" date.

## 13. Contact

- **Email:** [chatfort@yourhealingartist.com](mailto:chatfort@yourhealingartist.com)
- **GitHub:** [https://github.com/TheHealer28/ChatFort](https://github.com/TheHealer28/ChatFort)

## 14. Open source

ChatFort is open source under the AGPLv3 licence, and you can check how it handles your data in the
source code on GitHub. To protect users, the server addresses aren't published there.
