//
//  CallTypes.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 05/05/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import Foundation
import SwiftUI

public struct WebRTCCallOffer: Encodable {
    public init(callType: CallType, rtcSession: WebRTCSession) {
        self.callType = callType
        self.rtcSession = rtcSession
    }

    public var callType: CallType
    public var rtcSession: WebRTCSession
}

public struct WebRTCSession: Codable {
    public init(rtcSession: String, rtcIceCandidates: String) {
        self.rtcSession = rtcSession
        self.rtcIceCandidates = rtcIceCandidates
    }

    public var rtcSession: String
    public var rtcIceCandidates: String
}

public struct WebRTCExtraInfo: Codable {
    public init(rtcIceCandidates: String) {
        self.rtcIceCandidates = rtcIceCandidates
    }

    public var rtcIceCandidates: String
}

public struct RcvCallInvitation: Decodable {
    public var user: User
    public var contact: Contact
    public var callType: CallType
    public var sharedKey: String?
    public var callUUID: String?
    public var callTs: Date
    public var callTypeText: LocalizedStringKey {
        get {
            switch callType.media {
            case .video: return sharedKey == nil ? "video call (not e2e encrypted)" : "**e2e encrypted** video call"
            case .audio: return sharedKey == nil ? "audio call (not e2e encrypted)" : "**e2e encrypted** audio call"
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case user, contact, callType, sharedKey, callUUID, callTs
    }

    public static let sampleData = RcvCallInvitation(
        user: User.sampleData,
        contact: Contact.sampleData,
        callType: CallType(media: .audio, capabilities: CallCapabilities(encryption: false)),
        callTs: .now
    )
}

public struct CallType: Codable {
    public init(media: CallMediaType, capabilities: CallCapabilities) {
        self.media = media
        self.capabilities = capabilities
    }

    public var media: CallMediaType
    public var capabilities: CallCapabilities
}

public enum CallMediaType: String, Codable, Equatable {
    case video = "video"
    case audio = "audio"
}

public enum CallMediaSource: String, Codable, Equatable {
  case mic = "mic"
  case camera = "camera"
  case screenAudio = "screenAudio"
  case screenVideo = "screenVideo"
  case unknown = "unknown"
}

public enum VideoCamera: String, Codable, Equatable {
    case user = "user"
    case environment = "environment"
}

public struct CallCapabilities: Codable, Equatable {
    public var encryption: Bool

    public init(encryption: Bool) {
        self.encryption = encryption
    }
}

public enum WebRTCCallStatus: String, Encodable {
    case connected = "connected"
    case connecting = "connecting"
    case disconnected = "disconnected"
    case failed = "failed"
}

// MARK: - Group call control (Inqalaab)
// Lives in the framework so BOTH the app and the NSE can parse the hidden
// group-call control messages (the NSE must suppress them / surface an
// incoming-call notification instead of a generic "message" notification).

public enum GroupCallControlKind: String, Codable {
    case start   // a member announces a new call instance + participant roster
    case join    // a member announces they are joining an existing instance
    case leave   // a member announces they are leaving
}

public struct GroupCallControl: Codable, Equatable {
    /// Zero-width space + namespaced, versioned tag. Bump GC1→GC2 on format change.
    public static let marker = "\u{200B}ICF-GC1"

    public var kind: GroupCallControlKind
    /// Unique per call session — distinguishes concurrent/sequential calls in one group.
    public var instanceId: String
    public var groupId: Int64
    /// Sender's stable memberId within the group.
    public var fromMemberId: String
    /// Media type, present on `.start`.
    public var media: CallMediaType?
    /// Roster of participant memberIds, present on `.start`.
    public var participantMemberIds: [String]?

    public init(kind: GroupCallControlKind, instanceId: String, groupId: Int64, fromMemberId: String, media: CallMediaType? = nil, participantMemberIds: [String]? = nil) {
        self.kind = kind
        self.instanceId = instanceId
        self.groupId = groupId
        self.fromMemberId = fromMemberId
        self.media = media
        self.participantMemberIds = participantMemberIds
    }

    /// Serialize to a sentinel-prefixed text payload suitable for a `.text` message.
    public func encodedText() -> String {
        let json = (try? JSONEncoder().encode(self))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "\(GroupCallControl.marker) \(json)"
    }

    /// Parse a received message's text. Returns nil for any normal message — the
    /// receive interceptors use nil to mean "not a control message, leave it
    /// alone", so this must never match ordinary user text (the marker guards that).
    public static func parse(_ text: String) -> GroupCallControl? {
        guard text.hasPrefix(marker) else { return nil }
        let jsonPart = text.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        guard let data = jsonPart.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GroupCallControl.self, from: data)
    }
}

// MARK: - Cold-start handoff (NSE → app) for incoming group calls
// When the app is killed, the NSE receives the `.start` control. It persists it
// here (app group defaults) so the app rings the group call on next launch
// instead of letting the leg invitations degrade into 1:1 calls.

let GROUP_CALL_PENDING_JSON = "inqalaabPendingGroupCallControlJson"
let GROUP_CALL_PENDING_TS = "inqalaabPendingGroupCallControlTs"

public func savePendingGroupCallStart(_ control: GroupCallControl, at ts: Date) {
    if let data = try? JSONEncoder().encode(control), let json = String(data: data, encoding: .utf8) {
        groupDefaults.set(json, forKey: GROUP_CALL_PENDING_JSON)
        groupDefaults.set(ts.timeIntervalSince1970, forKey: GROUP_CALL_PENDING_TS)
    }
}

public func takePendingGroupCallStart(maxAge: TimeInterval) -> (control: GroupCallControl, ts: Date)? {
    guard let json = groupDefaults.string(forKey: GROUP_CALL_PENDING_JSON) else { return nil }
    let ts = Date(timeIntervalSince1970: groupDefaults.double(forKey: GROUP_CALL_PENDING_TS))
    clearPendingGroupCallStart()
    guard ts.timeIntervalSinceNow > -maxAge,
          let data = json.data(using: .utf8),
          let control = try? JSONDecoder().decode(GroupCallControl.self, from: data)
    else { return nil }
    return (control, ts)
}

public func hasFreshPendingGroupCallStart(maxAge: TimeInterval) -> Bool {
    guard groupDefaults.string(forKey: GROUP_CALL_PENDING_JSON) != nil else { return false }
    let ts = Date(timeIntervalSince1970: groupDefaults.double(forKey: GROUP_CALL_PENDING_TS))
    return ts.timeIntervalSinceNow > -maxAge
}

public func clearPendingGroupCallStart() {
    groupDefaults.removeObject(forKey: GROUP_CALL_PENDING_JSON)
    groupDefaults.removeObject(forKey: GROUP_CALL_PENDING_TS)
}
