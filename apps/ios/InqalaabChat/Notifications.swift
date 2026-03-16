//
//  Notifications.swift
//  SimpleX
//
//  Created by Evgeny on 28/04/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import Foundation
import UserNotifications
import SwiftUI
import Intents

public let ntfCategoryContactRequest = "NTF_CAT_CONTACT_REQUEST"
public let ntfCategoryContactConnected = "NTF_CAT_CONTACT_CONNECTED"
public let ntfCategoryMessageReceived = "NTF_CAT_MESSAGE_RECEIVED"
public let ntfCategoryCallInvitation = "NTF_CAT_CALL_INVITATION"
public let ntfCategoryConnectionEvent = "NTF_CAT_CONNECTION_EVENT"
public let ntfCategoryManyEvents = "NTF_CAT_MANY_EVENTS"
public let ntfCategoryCheckMessage = "NTF_CAT_CHECK_MESSAGE"

public let appNotificationId = "com.inqalaab.app.notification"

let contactHidden = NSLocalizedString("Contact hidden:", comment: "notification")

public func createContactRequestNtf(_ user: any UserLike, _ contactRequest: UserContactRequest, _ badgeCount: Int) -> UNMutableNotificationContent {
    let hideContent = ntfPreviewModeGroupDefault.get() == .hidden
    return createNotification(
        categoryIdentifier: ntfCategoryContactRequest,
        title: String.localizedStringWithFormat(
            NSLocalizedString("%@ wants to connect!", comment: "notification title"),
            hideContent ? NSLocalizedString("Somebody", comment: "notification title") : contactRequest.displayName
        ),
        body: String.localizedStringWithFormat(
            NSLocalizedString("Accept contact request from %@?", comment: "notification body"),
            hideContent ? NSLocalizedString("this contact", comment: "notification title") : contactRequest.chatViewName
        ),
        targetContentIdentifier: nil,
        userInfo: ["chatId": contactRequest.id, "contactRequestId": contactRequest.apiId, "userId": user.userId],
        badgeCount: badgeCount
    )
}

public func createContactConnectedNtf(_ user: any UserLike, _ contact: Contact, _ badgeCount: Int) -> UNMutableNotificationContent {
    let hideContent = ntfPreviewModeGroupDefault.get() == .hidden
    return createNotification(
        categoryIdentifier: ntfCategoryContactConnected,
        title: String.localizedStringWithFormat(
            NSLocalizedString("%@ is connected!", comment: "notification title"),
            hideContent ? NSLocalizedString("A new contact", comment: "notification title") : contact.displayName
        ),
        body: String.localizedStringWithFormat(
            NSLocalizedString("You can now chat with %@", comment: "notification body"),
            hideContent ? NSLocalizedString("this contact", comment: "notification title") : contact.chatViewName
        ),
        targetContentIdentifier: contact.id,
        userInfo: ["userId": user.userId],
//            userInfo: ["chatId": contact.id, "contactId": contact.apiId]
        badgeCount: badgeCount
    )
}

public func createMessageReceivedNtf(_ user: any UserLike, _ cInfo: ChatInfo, _ cItem: ChatItem, _ badgeCount: Int) -> UNMutableNotificationContent {
    let previewMode = ntfPreviewModeGroupDefault.get()
    var title: String
    if case let .group(groupInfo, _) = cInfo, case let .groupRcv(groupMember) = cItem.chatDir {
        title = groupMsgNtfTitle(groupInfo, groupMember, hideContent: previewMode == .hidden)
    } else {
        title = previewMode == .hidden ? contactHidden : "\(cInfo.chatViewName):"
    }
    return createNotification(
        categoryIdentifier: ntfCategoryMessageReceived,
        title: title,
        body: previewMode == .message ? hideSecrets(cItem) : NSLocalizedString("new message", comment: "notification"),
        targetContentIdentifier: cInfo.id,
        userInfo: ["userId": user.userId],
//            userInfo: ["chatId": cInfo.id, "chatItemId": cItem.id]
        badgeCount: badgeCount
    )
}

/// Unique notification identifier for call invitations (avoids reusing the shared appNotificationId)
public let callInvitationNtfId = "com.inqalaab.app.call-invitation"

public func createCallInvitationNtf(_ invitation: RcvCallInvitation, _ badgeCount: Int) -> UNMutableNotificationContent {
    let text = invitation.callType.media == .video
                ? NSLocalizedString("Incoming video call", comment: "notification")
                : NSLocalizedString("Incoming audio call", comment: "notification")
    let hideContent = ntfPreviewModeGroupDefault.get() == .hidden
    let content = createNotification(
        categoryIdentifier: ntfCategoryCallInvitation,
        title: hideContent ? contactHidden : "\(invitation.contact.chatViewName):",
        body: text,
        targetContentIdentifier: nil,
        userInfo: ["chatId": invitation.contact.id, "userId": invitation.user.userId],
        badgeCount: badgeCount
    )
    // Custom ringtone for incoming calls (~29 s, under Apple's 30 s limit).
    // The file is in the "sounds" folder reference which is a bundle resource.
    content.sound = UNNotificationSound(named: UNNotificationSoundName("sounds/ringtone.caf"))
    // Time-sensitive: breaks through Focus / Scheduled Summary
    if #available(iOS 15.0, *) {
        content.interruptionLevel = .timeSensitive
    }
    return content
}

/// Wraps the base call notification with a Communication Notification (iOS 15+).
/// Uses INSendMessageIntent so the system shows the caller's avatar and name
/// prominently — the best presentation available without CallKit.
public func createCallCommunicationNtf(_ invitation: RcvCallInvitation, _ badgeCount: Int) -> UNNotificationContent {
    let base = createCallInvitationNtf(invitation, badgeCount)
    guard #available(iOS 15.0, *) else { return base }

    // Build INPerson for the caller
    let handle = INPersonHandle(value: invitation.contact.id, type: .unknown)
    var avatar: INImage? = nil
    if let imageStr = invitation.contact.image,
       let data = Data(base64Encoded: dropImagePrefix(imageStr)) {
        avatar = INImage(imageData: data)
    }
    let caller = INPerson(
        personHandle: handle,
        nameComponents: nil,
        displayName: invitation.contact.chatViewName,
        image: avatar,
        contactIdentifier: nil,
        customIdentifier: invitation.contact.id,
        isMe: false
    )

    // Apple's updating(from:) only supports INSendMessageIntent,
    // so we use it to get the communication notification appearance
    // (avatar, prominent sender name) even for call invitations.
    let callText = invitation.callType.media == .video
        ? NSLocalizedString("Incoming video call", comment: "notification")
        : NSLocalizedString("Incoming audio call", comment: "notification")
    let intent = INSendMessageIntent(
        recipients: nil,
        outgoingMessageType: .outgoingMessageText,
        content: callText,
        speakableGroupName: nil,
        conversationIdentifier: invitation.contact.id,
        serviceName: nil,
        sender: caller,
        attachments: nil
    )

    // Donate interaction so the system learns about this caller
    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = .incoming
    interaction.donate(completion: nil)

    // Update notification content — adds avatar & prominent sender name.
    // updating(from:) returns a new object that may lose sound/interruptionLevel,
    // so we re-apply them on a mutable copy.
    do {
        let updated = try base.updating(from: intent)
        let result = updated.mutableCopy() as! UNMutableNotificationContent
        result.sound = UNNotificationSound(named: UNNotificationSoundName("sounds/ringtone.caf"))
        result.interruptionLevel = .timeSensitive
        return result
    } catch {
        logger.error("Communication notification update failed: \(error.localizedDescription)")
        return base
    }
}

public func createConnectionEventNtf(_ user: User, _ connEntity: ConnectionEntity, _ badgeCount: Int) -> UNMutableNotificationContent {
    let hideContent = ntfPreviewModeGroupDefault.get() == .hidden
    var title: String
    var body: String? = nil
    var targetContentIdentifier: String? = nil
    switch connEntity {
    case let .rcvDirectMsgConnection(_, contact):
        if let contact = contact {
            title = hideContent ? contactHidden : "\(contact.chatViewName):"
            targetContentIdentifier = contact.id
        } else {
            title = NSLocalizedString("New contact:", comment: "notification")
        }
        body = NSLocalizedString("message received", comment: "notification")
    case let .rcvGroupMsgConnection(_, groupInfo, groupMember):
        title = groupMsgNtfTitle(groupInfo, groupMember, hideContent: hideContent)
        body = NSLocalizedString("message received", comment: "notification")
        targetContentIdentifier = groupInfo.id
    case .sndFileConnection:
        title = NSLocalizedString("Sent file event", comment: "notification")
    case .rcvFileConnection:
        title = NSLocalizedString("Received file event", comment: "notification")
    case .userContactConnection:
        title = NSLocalizedString("New contact request", comment: "notification")
    }
    return createNotification(
        categoryIdentifier: ntfCategoryConnectionEvent,
        title: title,
        body: body,
        targetContentIdentifier: targetContentIdentifier,
        userInfo: ["userId": user.userId],
        badgeCount: badgeCount
    )
}

public func createErrorNtf(_ dbStatus: DBMigrationResult, _ badgeCount: Int) -> UNMutableNotificationContent {
    var title: String
    switch dbStatus {
    case .errorNotADatabase:
        title = NSLocalizedString("Encrypted message: no passphrase", comment: "notification")
    case .errorMigration:
        title = NSLocalizedString("Encrypted message: database migration error", comment: "notification")
    case .errorSQL:
        title = NSLocalizedString("Encrypted message: database error", comment: "notification")
    case .errorKeychain:
        title = NSLocalizedString("Encrypted message: keychain error", comment: "notification")
    case .unknown:
        title = NSLocalizedString("Encrypted message: unexpected error", comment: "notification")
    case .invalidConfirmation:
        title = NSLocalizedString("Encrypted message or another event", comment: "notification")
    case .ok:
        title = NSLocalizedString("Encrypted message or another event", comment: "notification")
    }
    return createNotification(
        categoryIdentifier: ntfCategoryConnectionEvent,
        title: title,
        badgeCount: badgeCount
    )
}

public func createAppStoppedNtf(_ badgeCount: Int) -> UNMutableNotificationContent {
    return createNotification(
        categoryIdentifier: ntfCategoryConnectionEvent,
        title: NSLocalizedString("Encrypted message: app is stopped", comment: "notification"),
        badgeCount: badgeCount
    )
}

private func groupMsgNtfTitle(_ groupInfo: GroupInfo, _ groupMember: GroupMember, hideContent: Bool) -> String {
    hideContent
    ? NSLocalizedString("Group message:", comment: "notification")
    : "#\(groupInfo.displayName) \(groupMember.chatViewName):"
}

public func createNotification(
    categoryIdentifier: String,
    title: String,
    subtitle: String? = nil,
    body: String? = nil,
    targetContentIdentifier: String? = nil,
    userInfo: [AnyHashable : Any] = [:],
    badgeCount: Int
) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.categoryIdentifier = categoryIdentifier
    content.title = title
    if let s = subtitle { content.subtitle = s }
    if let s = body { content.body = s }
    content.targetContentIdentifier = targetContentIdentifier
    content.userInfo = userInfo
    // TODO move logic of adding sound here, so it applies to background notifications too
    content.sound = .default
    content.badge = badgeCount as NSNumber
//        content.interruptionLevel = .active
//        content.relevanceScore = 0.5 // 0-1
    return content
}

func hideSecrets(_ cItem: ChatItem) -> String {
    if let md = cItem.formattedText {
        var res = ""
        for ft in md {
            if case .secret = ft.format {
                res = res + "..."
            } else {
                res = res + ft.text
            }
        }
        return res
    } else {
        let mc = cItem.content.msgContent
        if case let .report(text, reason) = mc {
            return String.localizedStringWithFormat(NSLocalizedString("Report: %@", comment: "report in notification"), text.isEmpty ? reason.text : text)
        } else {
            return cItem.text
        }
    }
}
