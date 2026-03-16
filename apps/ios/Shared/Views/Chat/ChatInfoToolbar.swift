//
//  ChatInfoToolbar.swift
//  SimpleX
//
//  Created by Evgeny Poberezkin on 11/02/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI
import InqalaabChat

struct ChatInfoToolbar: View {
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var chatModel: ChatModel
    @ObservedObject var chat: Chat
    var imageSize: CGFloat = 32

    var body: some View {
        let cInfo = chat.chatInfo
        return HStack {
            if (cInfo.incognito) {
                Image(systemName: "theatermasks").frame(maxWidth: 24, maxHeight: 24, alignment: .center).foregroundColor(.indigo)
                Spacer().frame(width: 16)
            }
            ZStack(alignment: .bottomTrailing) {
                ChatInfoImage(
                    chat: chat,
                    size: imageSize,
                    color: Color(uiColor: .tertiaryLabel)
                )
                if chat.chatStats.reportsCount > 0 {
                    Image(systemName: "flag.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                } else if chat.supportUnreadCount > 0 {
                    Image(systemName: "flag.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, theme.colors.primary)
                }
            }
            .padding(.trailing, 4)
            // Inqalaab: green connectivity dot
            Circle()
                .fill(chatModel.chatRunning == true ? InqalaabGreen : Color.orange)
                .frame(width: 8, height: 8)
                .padding(.trailing, 2)
            let t = Text(cInfo.displayName)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            (cInfo.contact?.verified == true ? contactVerifiedShield + t : t)
                .lineLimit(1)
                .if (cInfo.fullName != "" && cInfo.displayName != cInfo.fullName) { v in
                    VStack(spacing: 0) {
                        v
                        Text(cInfo.fullName)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(theme.colors.secondary)
                            .lineLimit(1)
                            .padding(.top, -2)
                    }
                }
        }
        .foregroundColor(theme.colors.onBackground)
        .frame(width: 220)
    }

    private var contactVerifiedShield: Text {
        (Text(Image(systemName: "checkmark.shield")) + textSpace)
            .font(.caption)
            .foregroundColor(InqalaabGreen)
            .baselineOffset(1)
            .kerning(-2)
    }
}

struct ChatInfoToolbar_Previews: PreviewProvider {
    static var previews: some View {
        ChatInfoToolbar(chat: Chat(chatInfo: ChatInfo.sampleData.direct, chatItems: []))
            .environmentObject(CurrentColors.toAppTheme())
    }
}
