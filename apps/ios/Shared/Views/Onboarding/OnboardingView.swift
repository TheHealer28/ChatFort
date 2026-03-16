//
//  OnboardingStepsView.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 07/05/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI

struct OnboardingView: View {
    var onboarding: OnboardingStage

    var body: some View {
        NavigationView {
            switch onboarding {
            case .step1_InqalaabInfo:
                InqalaabInfo(onboarding: true)
                    .modifier(ThemedBackground())
            case .step1b_InqalaabMission:
                InqalaabMissionView()
                    .modifier(ThemedBackground())
            case .step1c_SecurityPledge:
                InqalaabSecurityPledgeView()
                    .modifier(ThemedBackground())
            case .step2_CreateProfile: // deprecated
                CreateFirstProfile()
                    .modifier(ThemedBackground())
            case .step3_CreateInqalaabAddress: // deprecated
                CreateInqalaabAddress()
            case .step3_ChooseServerOperators:
                OnboardingConditionsView()
                    .navigationBarBackButtonHidden(true)
                    .modifier(ThemedBackground())
            case .step4_SetNotificationsMode:
                SetNotificationsMode()
                    .navigationBarBackButtonHidden(true)
                    .modifier(ThemedBackground())
            case .onboardingComplete: EmptyView()
            }
        }
    }
}

func onboardingButtonPlaceholder() -> some View {
    Spacer().frame(height: 40)
}

enum OnboardingStage: String, Identifiable {
    case step1_InqalaabInfo          // Inqalaab: Welcome screen
    case step1b_InqalaabMission     // Inqalaab: Mission statement (NEW)
    case step1c_SecurityPledge      // Inqalaab: Security pledge (NEW)
    case step2_CreateProfile        // deprecated
    case step3_CreateInqalaabAddress // deprecated
    case step3_ChooseServerOperators // simplified conditions
    case step4_SetNotificationsMode
    case onboardingComplete

    public var id: Self { self }
}

struct OnboardingStepsView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(onboarding: .step1_InqalaabInfo)
    }
}
