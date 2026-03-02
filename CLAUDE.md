# Inqalaab - Activist Communication App

## Project Overview
Inqalaab is a fork of **SimpleX Chat** (open-source, privacy-first messaging) customized for activists in Pakistan/India. The name means "Revolution" in Urdu. The app provides encrypted messaging that works even during internet shutdowns via peer-to-peer Nearby communication.

**Repository**: `/Users/malikswork/projects/simplex-chat`
**Developer**: Malik (Your Healing Artist Limited)
**Bundle ID**: `com.inqalaab.app`
**Apple Developer Team ID**: `C7P2NWA933`
**Team Name**: Your Healing Artist Limited

---

## Architecture

### Core Stack
- **iOS app**: Swift/SwiftUI (`apps/ios/`)
- **Backend engine**: Haskell FFI library (pre-built static libs in `apps/ios/Libraries/ios/`)
- **Messaging protocol**: SMP (SimpleX Messaging Protocol)
- **File transfer**: XFTP protocol
- **P2P**: MultipeerConnectivity framework (Bluetooth + WiFi, no internet needed)

### Key Directories
```
apps/ios/
  Shared/
    Model/          # ChatModel, SimpleXAPI, AppAPITypes, NtfManager
    Nearby/         # P2P messaging (NearbyTypes, NearbyStore, NearbyService, NearbyModel)
    Views/
      ChatList/     # ChatListView (modified with Nearby toggle + reactive subviews), ChatListNavLink
      Helpers/      # NavLinkPlain (original Button pattern), NavStackCompat (iOS 15 fallback only)
      Nearby/       # NearbyModeToggle, NearbyPeerListView, NearbyConversationView, etc.
      Onboarding/   # InqalaabOnboardingView, SetNotificationsMode, CreateProfile, etc.
      NewChat/      # NewChatView (QR scanning, planAndConnect flow)
      SafetyHub/    # SafetyHubView (Panic Mode)
      UserSettings/ # SettingsView, NetworkAndServers, PrivacySettings, UserAddressView
      LocalAuth/    # LocalAuthView
    InqalaabServers.swift    # Custom server configuration (replaces SimpleX servers)
    InqalaabTabView.swift    # Custom tab bar (Chats, Safety Hub)
    ContentView.swift        # App lifecycle, Nearby background/foreground handling
    SimpleXApp.swift         # App entry, scenePhase handling, InqalaabServers trigger
  SimpleX NSE/     # Notification Service Extension
  SimpleX SE/      # Share Extension
  SimpleXChat/     # Framework (Haskell FFI bridge, API types, ChatTypes)
  SimpleX.xcodeproj/
```

### Navigation System (Inqalaab-Modified)

**iOS 16+ (Primary)**: ChatListView uses an inline `NavigationStack` with `@State private var chatNavigationPath: [Bool]`. Two `onChange` handlers provide bidirectional sync between `chatModel.chatId` and the navigation path:
- `chatModel.chatId` changes → `chatNavigationPath` updated → NavigationStack pushes/pops
- User taps back → `chatNavigationPath` empties → `chatModel.chatId` set to nil

**iOS 15 Fallback**: Uses `NavStackCompat` wrapper with `NavigationView` + `NavigationLink(isActive:)`.

**Why not NavStackCompat for iOS 16+?**: NavStackCompat creates a computed `Binding` for NavigationStack's `path`. SwiftUI's NavigationStack doesn't actively re-read computed bindings — it only checks when the container view's body is re-evaluated. NavStackCompat's body becomes stale (SwiftUI can't compare closure properties for diffing), so the NavigationStack never sees path changes. Using `@State` for the path ensures SwiftUI properly observes it.

**NavLinkPlain**: Uses original `Button("")` in ZStack pattern. The Button calls `ItemsModel.shared.loadOpenChat(chatId)` which sets `chatModel.chatId` after a 250ms delay.

**oneHandUI**: The chat list uses `scaleEffect(x: 1, y: -1)` to flip the entire list, with each row flipped back individually.

### Reactive Subviews in ChatListView

The chat list content is rendered by two separate View structs with their own `@EnvironmentObject` observation. This ensures SwiftUI directly invalidates them when ChatModel publishes changes, bypassing the stale closure issue inside NavigationStack's content closure.

- **`ChatListRows`** (private struct): Renders the `ForEach` of chat rows. Has `@EnvironmentObject var chatModel: ChatModel` so it re-evaluates when `chatModel.chats` changes.
- **`ChatListQROverlay`** (private struct): Shows the user's QR code when no real chats exist (ignoring Notes). Has `@EnvironmentObject var chatModel: ChatModel` so it reactively hides when a contact connects. Uses `.padding(.bottom, 300)` to position above list content.

### Chat State Lifecycle
- `contactConnection` (pending `:connId`) → `contactRequest` (`<@requestId`) → `direct` (`@contactId`)
- Each state renders differently in `ChatListNavLink`
- The `processReceivedMsg()` function in `SimpleXAPI.swift` handles backend events: `contactConnected`, `contactConnecting`, `receivedContactRequest`, `newChatItems`, etc.
- `@Published private(set) var chats: [Chat]` on `ChatModel` drives the UI

### QR Code Scanning Flow (Inqalaab-modified)
When a user scans another device's QR code:
1. `planAndConnect()` → `apiConnectPlan()` → determines link type
2. For contact addresses: **directly calls `connectViaLink()`** (Inqalaab skips the "prepare contact card" step)
3. `connectViaLink()` → `apiConnect()` → backend creates connection → returns `PendingContactConnection`
4. `ChatModel.shared.updateContactConnection(pcc)` adds `:connId` pending chat to list
5. Backend events (`contactConnecting` → `contactConnected`) update the chat to `@contactId`
6. **Original SimpleX** uses `apiPrepareContact` (creates hidden "contact card" first, user must manually tap "Connect") — Inqalaab bypasses this for instant connections

---

## Inqalaab Servers (Self-Hosted)
- **SMP**: `smp://0000000000000000000000000000000000000000003=@smp.example.net`
- **XFTP**: `xftp://0000000000000000000000000000000000000000013=@xftp.example.net`
- **Host**: `example.net`
- **Configured in**: `InqalaabServers.swift` — auto-replaces SimpleX servers on first launch
- **Called from**: `SimpleXApp.swift` line 91–94, onboarding views, ChatListView.onAppear

### InqalaabServers.configureIfNeeded() — What It Does
1. **Replaces servers**: Repurposes SimpleX SMP/XFTP operator servers with Inqalaab host, disables all SimpleX operators
2. **Deletes preset contacts**: Removes "SimpleX Status" and "Ask SimpleX Team"
3. **Creates user address**: Calls `apiCreateUserAddress()` to generate the user's QR code
4. **Enables auto-accept**: Calls `apiSetUserAddressSettings()` so contacts who scan the QR are auto-connected (no manual accept needed)
5. **Concurrency guard**: `isConfiguring` flag prevents duplicate simultaneous runs

### Timing / Call Sites
- `SimpleXApp.swift` scene phase → `.active` (3s delay, for returning users)
- After onboarding completes in `SetNotificationsMode.swift`, `CreateProfile.swift`, `LocalAuthView.swift` (2s delay)
- `ChatListView.swift` `.onAppear` (1.5s delay, safety net)
- All guarded by `chatRunning == true && currentUser != nil`

---

## Build Instructions

### Prerequisites
- Xcode (latest)
- Pre-built Haskell static libraries in `apps/ios/Libraries/ios/` (downloaded from Hydra CI)
- Apple Developer account (Team: Your Healing Artist Limited)

### Build Command (CLI)
```bash
cd /Users/malikswork/projects/simplex-chat
xcodebuild -project apps/ios/SimpleX.xcodeproj \
  -scheme "SimpleX (iOS)" \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build
```
Note: CLI builds use `CODE_SIGN_IDENTITY=""` to skip signing (Ad Hoc signing fails on iOS 26.2 SDK). For device deployment, build from Xcode IDE.

### Build in Xcode
1. Open `apps/ios/SimpleX.xcodeproj`
2. Select scheme: **SimpleX (iOS)** (NOT SimpleXChat)
3. Select destination: **Muhammad's iPhone** or **Any iOS Device**
4. `Cmd + R` to run, `Cmd + B` to build only

### Signing
- All 3 targets signed with Team **C7P2NWA933** (Your Healing Artist Limited):
  - SimpleX (iOS) — main app
  - SimpleX NSE — notification extension
  - SimpleX SE — share extension
- Automatically managed signing enabled
- SimpleXChat framework and Tests iOS do NOT need manual team selection

---

## What Has Been Completed

### Session 1 & 2: UI Differentiation & Nearby P2P
- [x] Custom theme/colors (Inqalaab green/teal gradient)
- [x] InqalaabTabView (Chats + Safety Hub tabs)
- [x] Safety Hub with Panic Mode (shake to wipe)
- [x] Custom onboarding flow (InqalaabOnboardingView, InqalaabSecurityPledgeView)
- [x] Urdu language support
- [x] Custom message bubbles
- [x] App icon (raised fist with digital circuit design) for both light and dark mode
- [x] **Nearby P2P Messaging** — Full MultipeerConnectivity implementation:
  - NearbyTypes, NearbyStore, NearbyService, NearbyModel
  - NearbyModeToggle, NearbyPeerListView, NearbyConversationView
  - NearbyMessageBubble, NearbyComposeBar, NearbyEmptyState
  - Service type: `"inqalaab-p2p"` (Bonjour)
  - Panic Mode integration: `NearbyModel.shared.clearAllData()`
- [x] ~1000+ string replacements across localization files (SimpleX → Inqalaab)

### Session 3: Xcode Project Configuration
- [x] Bundle Identifier: `com.inqalaab.app`
- [x] Display Name: Inqalaab
- [x] App Category: Social Networking
- [x] Created proper `.entitlements` files (were only `.entitlements.xml`)
- [x] Removed restricted entitlements needing Apple approval (multicast, device-name, notification-filtering)
- [x] Removed SimpleX associated domains
- [x] Changed all team IDs from `5NN7GUYB6T` (SimpleX) to `C7P2NWA933` (Inqalaab)
- [x] Removed missing playground references
- [x] Fixed notification default from `.instant` to `.off` (prevents crash)
- [x] App successfully builds and installs on physical device

### Session 4: Server Configuration & QR Code Fix
- [x] **InqalaabServers timing fix**: `configureIfNeeded()` now triggers after onboarding completes (was only running from `SimpleXApp.swift` scene phase change which required `currentUser != nil` — nil during onboarding)
- [x] **QR code not showing**: Root cause was `configureIfNeeded()` never running on first launch → `createUserAddress()` never called → `chatModel.userAddress` nil
- [x] **deletePresetContacts logic**: Fixed condition `found == deleted` (even when both are 0) to properly mark cleanup as complete
- [x] **duplicateContactLink error**: Added fallback in `createUserAddress()` — if `apiCreateUserAddress()` fails with duplicate, loads existing address via `apiGetUserAddressAsync()`
- [x] **Network & servers crash**: Fixed in earlier session (SaveableSettings + chatRunning guard)

### Session 5: Chat Not Appearing After QR Scan
- [x] **contactCard filtering fix**: Changed `planAndConnect()` in `NewChatView.swift` to call `connectViaLink()` directly instead of `showPrepareContactAlert()` (which creates hidden contact cards)
- [x] **updateChatInfo() re-render fix**: Changed to use reassign pattern (`chats[i] = chat`) to trigger `@Published`
- [x] **Auto-accept for user address**: Added `enableAutoAccept()` in `InqalaabServers.swift`
- [x] **Concurrency guard**: Added `isConfiguring` flag to prevent duplicate simultaneous execution
- [x] Added comprehensive diagnostic `print("Inqalaab ...")` logging throughout the event chain

### Session 6: Navigation & QR Overlay Fixes
Three bugs fixed and one UX improvement:

#### Bug 1: Chat list not updating (ForEach stale data)
- **Symptom**: After QR scan, backend events confirmed contact created, but ForEach never showed it
- **Root cause**: NavStackCompat stores content as a closure. SwiftUI can't compare closures for diffing, so it skips re-evaluating the content. The ForEach inside the closure used stale data.
- **Fix**: Extracted ForEach into `ChatListRows` — a separate View struct with `@EnvironmentObject var chatModel: ChatModel`. SwiftUI directly invalidates this struct when ChatModel publishes, bypassing the stale closure.

#### Bug 2: QR code not showing on main screen
- **Symptom**: QR overlay never appeared even though address was created
- **Root cause**: Condition `chatModel.chats.isEmpty` was never true because Notes (`*1`) always exists
- **Fix**: Created `ChatListQROverlay` — a separate reactive View struct that checks `hasRealChats` (ignoring Notes/local types). Shows QR when no real chats exist.

#### Bug 3: Chat not opening when tapped
- **Symptom**: Tapping a chat called `loadOpenChat`, API returned data, but navigation never fired
- **Root cause**: Same stale closure issue — NavStackCompat's body was never re-evaluated, so the NavigationStack's computed path Binding was stale. When `chatModel.chatId` was set, NavigationStack didn't see the change.
- **Fix**: Replaced NavStackCompat (for iOS 16+) with inline `NavigationStack` using `@State var chatNavigationPath: [Bool]`. Two `onChange` handlers sync `chatModel.chatId ↔ chatNavigationPath` bidirectionally. `@State` is properly observed by NavigationStack.
- Also reverted NavLinkPlain from `onTapGesture` back to original `Button("")` pattern.

#### UX: AddressCreationCard hidden when address exists
- **Fix**: Added `&& chatModel.userAddress == nil` to the condition for showing `AddressCreationCard`. Since Inqalaab auto-creates the address, this card was redundant and overlapped with the QR overlay.

#### Files Modified in Session 6
| File | Changes |
|------|---------|
| `ChatListView.swift` | Added `@State chatNavigationPath`; replaced NavStackCompat with inline NavigationStack + onChange sync for iOS 16+; kept NavStackCompat for iOS 15 fallback; added `ChatListRows` struct; added `ChatListQROverlay` struct; hid AddressCreationCard when address exists |
| `NavLinkPlain.swift` | Reverted to original `Button("")` in ZStack pattern (from `onTapGesture`) |

---

## Known Issues / TODO

### Crashes to Avoid
- **"Instant" notifications** — needs APNs/NTF server setup

### Diagnostic Logging (To Remove)
There is extensive `print("Inqalaab ...")` diagnostic logging throughout the codebase from debugging efforts. This should be removed before release:
- `SimpleXAPI.swift` — `Inqalaab RECV:`, `Inqalaab EVENT:`, `Inqalaab apiConnect:`
- `ChatModel.swift` — `Inqalaab updateChat:`, `Inqalaab updateChats:`, `Inqalaab removeChat:`, `Inqalaab addChatItem:`
- `ChatListView.swift` — `Inqalaab filteredChats:`, `Inqalaab chatView:`, `Inqalaab ChatListRows:`, `Inqalaab ChatListQROverlay:`, `Inqalaab navigation sync:`
- `ChatListNavLink.swift` — `Inqalaab ChatListNavLink:`
- `NavLinkPlain.swift` — `Inqalaab NavLinkPlain:`
- `InqalaabServers.swift` — Various `Inqalaab:` logs (some of these are useful to keep for production debugging)

### Pending Work
- [ ] Remove diagnostic `print()` logging (see list above)
- [ ] Set Version to `1.0.0` and Build to `1` (currently still 6.4.10 / 320)
- [ ] Set up NTF (notification) server on example.net for push notifications
- [ ] Request restricted entitlements from Apple if needed:
  - Multicast entitlement (for enhanced Nearby discovery)
  - Notification filtering (for NSE)
- [ ] Test Nearby P2P messaging between two iOS devices
- [ ] End-to-end test QR code scanning between two devices
- [ ] App Store submission (Archive → Upload to App Store Connect)
- [ ] App Store screenshots and metadata
- [ ] Privacy policy URL for App Store

---

## Bundle IDs
| Target | Bundle ID |
|--------|-----------|
| Main App | `com.inqalaab.app` |
| NSE | `com.inqalaab.app.Inqalaab-NSE` |
| SE | `com.inqalaab.app.Inqalaab-SE` |
| Framework | `com.inqalaab.SimpleXChat` |
| Tests | `com.inqalaab.Tests-iOS` |

### App Groups
- `group.com.inqalaab.app` (shared between main app, NSE, and SE)

### Keychain Groups
- `$(AppIdentifierPrefix)com.inqalaab.app`

---

## Important Notes

- The Haskell backend static libraries are pre-built (downloaded from SimpleX's Hydra CI). They are NOT compiled from source. They live in `apps/ios/Libraries/ios/`.
- The scheme name in Xcode is still "SimpleX (iOS)" — this is fine, it's just the internal target name.
- The NSE and SE extension target names are also still "SimpleX NSE" and "SimpleX SE" internally.
- The user-visible app name is "Inqalaab" (set via CFBundleDisplayName in InfoPlist.strings).
- Notification mode defaults to `.off` during onboarding to prevent crashes (no NTF server configured yet).
- The `simplex://` URL scheme is still registered in Info.plist, so QR codes generated by SimpleX/Inqalaab will open in this app when scanned by the system camera.
- `fopen failed for data file: errno = 2` errors in Xcode console are harmless (Haskell backend's internal file cache on first launch).
- `ObjC class implemented in both VFX.framework and SimpleXChat.framework` warning is harmless.
- `Couldn't read values in CFPrefsPlistSource` for `group.com.inqalaab.app` is a sandboxing warning, does not affect functionality.

### Key Architectural Decisions for Inqalaab
1. **Direct connect on QR scan** (no "prepare contact card" intermediate step) — faster UX for activists
2. **Auto-accept on user address** — anyone who scans your QR is instantly connected
3. **Self-hosted servers only** — all SimpleX operators disabled, only example.net servers used
4. **Preset contacts removed** — "SimpleX Status" and "Ask SimpleX Team" deleted on first launch
5. **Reactive subviews for SwiftUI** — `ChatListRows` and `ChatListQROverlay` use separate `@EnvironmentObject` observation to bypass stale closures inside NavigationStack
6. **@State-backed navigation** — Inline NavigationStack with `@State` path instead of NavStackCompat's computed Binding, ensuring navigation responds to chatModel.chatId changes
