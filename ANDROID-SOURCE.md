# ChatFort for Android: source

This branch holds the source of **ChatFort for Android 1.1.22 (35)**. That release adds Crowd mesh
offline contacts, photos and voice notes over Bluetooth, and works with ChatFort on iPhone 1.6.4. The
iPhone app's source is on the `main` branch.

ChatFort is built on the open-source SimpleX Chat apps and protocol. The Crowd mesh is in
`apps/multiplatform/mesh`.

## Not included
- **Server configuration** (`apps/multiplatform/android/src/main/java/chat/simplex/app/InqalaabServers.kt`):
  ChatFort's relay settings are not published. To build the app, add your own version of this file
  that points to your own SimpleX relays.
- **Signing keys, store credentials and build secrets**: never part of the source.
- **A test TLS key** (`tests/fixtures/tls/server.key`) used only by the server test suite.
