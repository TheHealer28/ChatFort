//
//  NetworkServersView.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 02/08/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI
import WebKit
import Ink
import InqalaabChat

private enum NetworkAlert: Identifiable {
    case error(err: String)

    var id: String {
        switch self {
        case let .error(err): return "error \(err)"
        }
    }
}

struct NetworkAndServers: View {
    @Environment(\.dismiss) var dismiss: DismissAction
    @EnvironmentObject var m: ChatModel
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var ss: SaveableSettings
    @State private var justOpened = true
    @State private var testing = false
    @State private var showAddSMPServer = false
    @State private var showAddXFTPServer = false
    @State private var newServerURI = ""

    var body: some View {
        VStack {
            List {
                // Inqalaab: show numbered server labels (addresses hidden)
                Section {
                    let allSmp = ss.servers.userServers.flatMap { $0.smpServers }.filter { $0.enabled && !$0.deleted }
                    let allXftp = ss.servers.userServers.flatMap { $0.xftpServers }.filter { $0.enabled && !$0.deleted }

                    ForEach(Array(allSmp.enumerated()), id: \.element.id) { idx, server in
                        HStack {
                            showTestStatus(server: server)
                                .frame(width: 16, alignment: .center)
                                .padding(.trailing, 4)
                            Text("Message Server \(idx + 1)")
                        }
                    }

                    ForEach(Array(allXftp.enumerated()), id: \.element.id) { idx, server in
                        HStack {
                            showTestStatus(server: server)
                                .frame(width: 16, alignment: .center)
                                .padding(.trailing, 4)
                            Text("Media Server \(idx + 1)")
                        }
                    }
                } header: {
                    Text("Messages and files")
                        .foregroundColor(theme.colors.secondary)
                }

                Section {
                    Button("Test servers") {
                        testAllServers()
                    }
                    .disabled(testing)
                }

                Section(header: Text("Add your own servers").foregroundColor(theme.colors.secondary)) {
                    Button {
                        newServerURI = ""
                        showAddSMPServer = true
                    } label: {
                        Label("Add message server", systemImage: "plus.circle")
                    }
                    Button {
                        newServerURI = ""
                        showAddXFTPServer = true
                    } label: {
                        Label("Add media server", systemImage: "plus.circle")
                    }
                }

                Section {
                    NavigationLink {
                        AdvancedNetworkSettings()
                            .navigationTitle("Advanced settings")
                            .modifier(ThemedBackground(grouped: true))
                    } label: {
                        Text("Advanced network settings")
                    }
                }

                Section(header: Text("Calls").foregroundColor(theme.colors.secondary)) {
                    NavigationLink {
                        RTCServers()
                            .navigationTitle("Your ICE servers")
                            .modifier(ThemedBackground(grouped: true))
                    } label: {
                        Text("WebRTC ICE servers")
                    }
                }

                Section(header: Text("Network connection").foregroundColor(theme.colors.secondary)) {
                    HStack {
                        Text(m.networkInfo.networkType.text)
                        Spacer()
                        Image(systemName: "circle.fill").foregroundColor(m.networkInfo.online ? .green : .red)
                    }
                }
            }
        }
        .opacity(testing ? 0.4 : 1)
        .overlay {
            if testing {
                ProgressView()
                    .scaleEffect(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .allowsHitTesting(!testing)
        .alert("Add message server", isPresented: $showAddSMPServer) {
            TextField("smp://...", text: $newServerURI)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Button("Add") { addCustomServer(uri: newServerURI, protocol: .smp) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paste your SMP server address")
        }
        .alert("Add media server", isPresented: $showAddXFTPServer) {
            TextField("xftp://...", text: $newServerURI)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Button("Add") { addCustomServer(uri: newServerURI, protocol: .xftp) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paste your XFTP server address")
        }
        .task {
            if justOpened {
                do {
                    guard m.chatRunning == true else {
                        justOpened = false
                        return
                    }
                    let servers: [UserOperatorServers]
                    if let managedServers = await InqalaabServers.shared.replaceManagedServersForSettings() {
                        servers = managedServers
                    } else {
                        servers = try await getUserServers()
                    }
                    await MainActor.run {
                        ss.servers.currUserServers = servers
                        ss.servers.userServers = servers
                        ss.servers.serverErrors = []
                    }
                } catch let error {
                    await MainActor.run {
                        showAlert(
                            NSLocalizedString("Error loading servers", comment: "alert title"),
                            message: responseError(error)
                        )
                    }
                }
                justOpened = false
            }
        }
    }

    @MainActor private func resetServerTestStatus() {
        for groupIdx in 0..<ss.servers.userServers.count {
            for srvIdx in 0..<ss.servers.userServers[groupIdx].smpServers.count {
                if ss.servers.userServers[groupIdx].smpServers[srvIdx].enabled {
                    ss.servers.userServers[groupIdx].smpServers[srvIdx].tested = nil
                }
            }
            for srvIdx in 0..<ss.servers.userServers[groupIdx].xftpServers.count {
                if ss.servers.userServers[groupIdx].xftpServers[srvIdx].enabled {
                    ss.servers.userServers[groupIdx].xftpServers[srvIdx].tested = nil
                }
            }
        }
    }

    private func addCustomServer(uri: String, protocol serverProtocol: ServerProtocol) {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = serverProtocol == .smp ? "smp://" : "xftp://"
        guard !trimmed.isEmpty, trimmed.hasPrefix(prefix) else {
            showAlert(
                NSLocalizedString("Invalid server address", comment: "alert title"),
                message: NSLocalizedString("Server address must start with \(prefix)", comment: "alert message")
            )
            return
        }

        guard !ss.servers.userServers.isEmpty else { return }
        let groupIdx = 0
        let newServer = UserServer(
            serverId: nil,
            server: trimmed,
            preset: false,
            tested: nil,
            enabled: true,
            deleted: false
        )

        if serverProtocol == .smp {
            ss.servers.userServers[groupIdx].smpServers.append(newServer)
        } else {
            ss.servers.userServers[groupIdx].xftpServers.append(newServer)
        }

        Task {
            do {
                let validationErrors = try await validateServers(userServers: ss.servers.userServers)
                if validationErrors.isEmpty {
                    try await setUserServers(userServers: ss.servers.userServers)
                    await MainActor.run {
                        ss.servers.currUserServers = ss.servers.userServers
                    }
                } else {
                    // Revert
                    await MainActor.run {
                        if serverProtocol == .smp {
                            ss.servers.userServers[groupIdx].smpServers.removeLast()
                        } else {
                            ss.servers.userServers[groupIdx].xftpServers.removeLast()
                        }
                    }
                    showAlert(
                        NSLocalizedString("Invalid server", comment: "alert title"),
                        message: NSLocalizedString("Server validation failed. Please check the address.", comment: "alert message")
                    )
                }
            } catch {
                await MainActor.run {
                    if serverProtocol == .smp {
                        ss.servers.userServers[groupIdx].smpServers.removeLast()
                    } else {
                        ss.servers.userServers[groupIdx].xftpServers.removeLast()
                    }
                }
                showAlert(
                    NSLocalizedString("Error", comment: "alert title"),
                    message: responseError(error)
                )
            }
        }
    }

    private func testAllServers() {
        testing = true
        Task {
            if let servers = await InqalaabServers.shared.replaceManagedServersForSettings() {
                await MainActor.run {
                    ss.servers.currUserServers = servers
                    ss.servers.userServers = servers
                    ss.servers.serverErrors = []
                    resetServerTestStatus()
                }
            } else {
                await MainActor.run {
                    resetServerTestStatus()
                }
            }

            var failures: [String: ProtocolTestFailure] = [:]

            for groupIdx in 0..<ss.servers.userServers.count {
                for srvIdx in 0..<ss.servers.userServers[groupIdx].smpServers.count {
                    if ss.servers.userServers[groupIdx].smpServers[srvIdx].enabled {
                        if let f = await testServerConnection(server: $ss.servers.userServers[groupIdx].smpServers[srvIdx]) {
                            failures[serverHostname(ss.servers.userServers[groupIdx].smpServers[srvIdx].server)] = f
                        }
                    }
                }
                for srvIdx in 0..<ss.servers.userServers[groupIdx].xftpServers.count {
                    if ss.servers.userServers[groupIdx].xftpServers[srvIdx].enabled {
                        if let f = await testServerConnection(server: $ss.servers.userServers[groupIdx].xftpServers[srvIdx]) {
                            failures[serverHostname(ss.servers.userServers[groupIdx].xftpServers[srvIdx].server)] = f
                        }
                    }
                }
            }

            await MainActor.run {
                testing = false
                if !failures.isEmpty {
                    let msg = failures.map { (srv, f) in
                        "\(srv): \(f.localizedDescription)"
                    }.joined(separator: "\n")
                    showAlert(
                        NSLocalizedString("Tests failed!", comment: "alert title"),
                        message: String.localizedStringWithFormat(NSLocalizedString("Some servers failed the test:\n%@", comment: "alert message"), msg)
                    )
                }
            }
        }
    }
}

struct UsageConditionsView: View {
    @Environment(\.dismiss) var dismiss: DismissAction
    @EnvironmentObject var theme: AppTheme
    @Binding var currUserServers: [UserOperatorServers]
    @Binding var userServers: [UserOperatorServers]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch ChatModel.shared.conditions.conditionsAction {

            case .none:
                regularConditionsHeader()
                    .padding(.top)
                    .padding(.top)
                ConditionsTextView()
                    .padding(.bottom)
                    .padding(.bottom)

            case let .review(operators, deadline, _):
                HStack {
                    Text("Updated conditions").font(.largeTitle).bold()
                }
                .padding(.top)
                .padding(.top)

                Text("Conditions will be accepted for the operator(s): **\(operators.map { $0.legalName_ }.joined(separator: ", "))**.")
                ConditionsTextView()
                VStack(spacing: 8) {
                    acceptConditionsButton(operators.map { $0.operatorId })
                    if let deadline = deadline {
                        Text("Conditions will be automatically accepted for enabled operators on: \(conditionsTimestamp(deadline)).")
                            .foregroundColor(theme.colors.secondary)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 32)
                        conditionsDiffButton(.footnote)
                    } else {
                        conditionsDiffButton()
                            .padding(.top)
                    }
                }
                .padding(.bottom)
                .padding(.bottom)
                

            case let .accepted(operators):
                regularConditionsHeader()
                    .padding(.top)
                    .padding(.top)
                Text("Conditions are accepted for the operator(s): **\(operators.map { $0.legalName_ }.joined(separator: ", "))**.")
                ConditionsTextView()
                    .padding(.bottom)
                    .padding(.bottom)
            }
        }
        .padding(.horizontal, 25)
        .frame(maxHeight: .infinity)
    }

    private func acceptConditionsButton(_ operatorIds: [Int64]) -> some View {
        Button {
            acceptForOperators(operatorIds)
        } label: {
            Text("Accept conditions")
        }
        .buttonStyle(OnboardingButtonStyle())
    }

    func acceptForOperators(_ operatorIds: [Int64]) {
        Task {
            do {
                let conditionsId = ChatModel.shared.conditions.currentConditions.conditionsId
                let r = try await acceptConditions(conditionsId: conditionsId, operatorIds: operatorIds)
                await MainActor.run {
                    ChatModel.shared.conditions = r
                    updateOperatorsConditionsAcceptance($currUserServers, r.serverOperators)
                    updateOperatorsConditionsAcceptance($userServers, r.serverOperators)
                    dismiss()
                }
            } catch let error {
                await MainActor.run {
                    showAlert(
                        NSLocalizedString("Error accepting conditions", comment: "alert title"),
                        message: responseError(error)
                    )
                }
            }
        }
    }

    @ViewBuilder private func conditionsDiffButton(_ font: Font? = nil) -> some View {
        let commit = ChatModel.shared.conditions.currentConditions.conditionsCommit
        if let commitUrl = URL(string: "https://github.com/TheHealer28/Inqalaab/commit/\(commit)") {
            Link(destination: commitUrl) {
                HStack {
                    Text("Open changes")
                    Image(systemName: "arrow.up.right.circle")
                }
                .font(font)
            }
        }
    }
}

private func regularConditionsHeader() -> some View {
    HStack {
        Text("Conditions of use").font(.largeTitle).bold()
        Spacer()
        conditionsLinkButton()
    }
}

struct SimpleConditionsView: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            regularConditionsHeader()
                .padding(.top)
                .padding(.top)
            ConditionsTextView()
                .padding(.bottom)
                .padding(.bottom)
        }
        .padding(.horizontal, 25)
        .frame(maxHeight: .infinity)
    }
}

func validateServers_(_ userServers: Binding<[UserOperatorServers]>, _ serverErrors: Binding<[UserServersError]>) {
    let userServersToValidate = userServers.wrappedValue
    Task {
        do {
            let errs = try await validateServers(userServers: userServersToValidate)
            await MainActor.run {
                serverErrors.wrappedValue = errs
            }
        } catch let error {
            logger.error("validateServers error: \(responseError(error))")
        }
    }
}

func serversCanBeSaved(
    _ currUserServers: [UserOperatorServers],
    _ userServers: [UserOperatorServers],
    _ serverErrors: [UserServersError]
) -> Bool {
    return userServers != currUserServers && serverErrors.isEmpty
}

struct ServersErrorView: View {
    @EnvironmentObject var theme: AppTheme
    var errStr: String

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.circle")
                .foregroundColor(.red)
            Text(errStr)
                .foregroundColor(theme.colors.secondary)
        }
    }
}

func globalServersError(_ serverErrors: [UserServersError]) -> String? {
    for err in serverErrors {
        if let errStr = err.globalError {
            return errStr
        }
    }
    return nil
}

func globalSMPServersError(_ serverErrors: [UserServersError]) -> String? {
    for err in serverErrors {
        if let errStr = err.globalSMPError {
            return errStr
        }
    }
    return nil
}

func globalXFTPServersError(_ serverErrors: [UserServersError]) -> String? {
    for err in serverErrors {
        if let errStr = err.globalXFTPError {
            return errStr
        }
    }
    return nil
}

func findDuplicateHosts(_ serverErrors: [UserServersError]) -> Set<String> {
    let duplicateHostsList = serverErrors.compactMap { err in
        if case let .duplicateServer(_, _, duplicateHost) = err {
            return duplicateHost
        } else {
            return nil
        }
    }
    return Set(duplicateHostsList)
}

func saveServers(_ currUserServers: Binding<[UserOperatorServers]>, _ userServers: Binding<[UserOperatorServers]>) {
    let userServersToSave = userServers.wrappedValue
    Task {
        do {
            try await setUserServers(userServers: userServersToSave)
            // Get updated servers to learn new server ids (otherwise it messes up delete of newly added and saved servers)
            do {
                let updatedServers = try await getUserServers()
                let updatedOperators = try await getServerOperators()
                await MainActor.run {
                    ChatModel.shared.conditions = updatedOperators
                    currUserServers.wrappedValue = updatedServers
                    userServers.wrappedValue = updatedServers
                }
            } catch let error {
                logger.error("saveServers getUserServers error: \(responseError(error))")
                await MainActor.run {
                    currUserServers.wrappedValue = userServersToSave
                }
            }
        } catch let error {
            logger.error("saveServers setUserServers error: \(responseError(error))")
            await MainActor.run {
                showAlert(
                    NSLocalizedString("Error saving servers", comment: "alert title"),
                    message: responseError(error)
                )
            }
        }
    }
}

func updateOperatorsConditionsAcceptance(_ usvs: Binding<[UserOperatorServers]>, _ updatedOperators: [ServerOperator]) {
    for i in 0..<usvs.wrappedValue.count {
        if let updatedOperator = updatedOperators.first(where: { $0.operatorId == usvs.wrappedValue[i].operator?.operatorId }) {
            usvs.wrappedValue[i].operator?.conditionsAcceptance = updatedOperator.conditionsAcceptance
        }
    }
}

// MARK: - Shared helpers (extracted from deleted ProtocolServerView.swift)

struct BackButton: ViewModifier {
    var label: LocalizedStringKey = "Back"
    @Binding var disabled: Bool
    var action: () -> Void

    func body(content: Content) -> some View {
        content
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: action) {
                    HStack {
                        Image(systemName: "chevron.left")
                        Text(label)
                    }
                }
                .disabled(disabled)
            }
        }
    }
}

@ViewBuilder func showTestStatus(server: UserServer) -> some View {
    switch server.tested {
    case .some(true):
        Image(systemName: "checkmark")
            .foregroundColor(.green)
    case .some(false):
        Image(systemName: "multiply")
            .foregroundColor(.red)
    case .none:
        Color.clear
    }
}

func testServerConnection(server: Binding<UserServer>) async -> ProtocolTestFailure? {
    do {
        let r = try await testProtoServer(server: server.wrappedValue.server)
        switch r {
        case .success:
            await MainActor.run { server.wrappedValue.tested = true }
            return nil
        case let .failure(f):
            await MainActor.run { server.wrappedValue.tested = false }
            return f
        }
    } catch let error {
        logger.error("testServerConnection \(responseError(error))")
        await MainActor.run {
            server.wrappedValue.tested = false
        }
        return nil
    }
}

func conditionsTimestamp(_ date: Date) -> String {
    let localDateFormatter = DateFormatter()
    localDateFormatter.dateStyle = .medium
    localDateFormatter.timeStyle = .none
    return localDateFormatter.string(from: date)
}

func conditionsLinkButton() -> some View {
    let commit = ChatModel.shared.conditions.currentConditions.conditionsCommit
    let mdUrl = URL(string: "https://github.com/TheHealer28/Inqalaab/blob/\(commit)/PRIVACY.md") ?? conditionsURL
    return Menu {
        Link(destination: mdUrl) {
            Label("Open conditions", systemImage: "doc")
        }
        if let commitUrl = URL(string: "https://github.com/TheHealer28/Inqalaab/commit/\(commit)") {
            Link(destination: commitUrl) {
                Label("Open changes", systemImage: "ellipsis")
            }
        }
    } label: {
        Image(systemName: "arrow.up.right.circle")
            .resizable()
            .scaledToFit()
            .frame(width: 20)
            .padding(2)
            .contentShape(Circle())
    }
}

struct ConditionsTextView: View {
    @State private var conditionsData: (UsageConditions, String?, UsageConditions?)?
    @State private var failedToLoad: Bool = false
    @State private var conditionsHTML: String? = nil

    let defaultConditionsLink = "https://github.com/TheHealer28/Inqalaab/blob/main/PRIVACY.md"

    var body: some View {
        viewBody()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                do {
                    let conditions = try await getUsageConditions()
                    let conditionsText = conditions.1
                    let parentLink =  "https://github.com/TheHealer28/Inqalaab/blob/\(conditions.0.conditionsCommit)"
                    let preparedText: String?
                    if let conditionsText {
                        let prepared = prepareMarkdown(conditionsText.trimmingCharacters(in: .whitespacesAndNewlines), parentLink)
                        conditionsHTML = MarkdownParser().html(from: prepared)
                        preparedText = prepared
                    } else {
                        preparedText = nil
                    }
                    conditionsData = (conditions.0, preparedText, conditions.2)
                } catch let error {
                    logger.error("ConditionsTextView getUsageConditions error: \(responseError(error))")
                    failedToLoad = true
                }
            }
    }

    @ViewBuilder private func viewBody() -> some View {
        if let (usageConditions, _, _) = conditionsData {
            if let conditionsHTML {
                ConditionsWebView(html: conditionsHTML)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )
            } else {
                let conditionsLink = "https://github.com/TheHealer28/Inqalaab/blob/\(usageConditions.conditionsCommit)/PRIVACY.md"
                conditionsLinkView(conditionsLink)
            }
        } else if failedToLoad {
            conditionsLinkView(defaultConditionsLink)
        } else {
            ProgressView()
                .scaleEffect(2)
        }
    }

    private func conditionsLinkView(_ conditionsLink: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Current conditions text couldn't be loaded, you can review conditions via this link:")
            Link(destination: URL(string: conditionsLink)!) {
                Text(conditionsLink)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private func prepareMarkdown(_ text: String, _ parentLink: String) -> String {
        let localLinkRegex = try! NSRegularExpression(pattern: "\\[([^\\(]*)\\]\\(#.*\\)")
        let h1Regex = try! NSRegularExpression(pattern: "^# ")
        var text = localLinkRegex.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count), withTemplate: "$1")
        text = h1Regex.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count), withTemplate: "")
        return text
            .replacingOccurrences(of: "](/", with: "](\(parentLink)/")
            .replacingOccurrences(of: "](./", with: "](\(parentLink)/")
    }
}

struct ConditionsWebView: UIViewRepresentable {
    @State var html: String
    @EnvironmentObject var theme: AppTheme
    @State var pageLoaded = false

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.navigationDelegate = context.coordinator
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if !pageLoaded {
                loadPage(view)
            }
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        loadPage(view)
    }

    private func loadPage(_ webView: WKWebView) {
        let styles = """
        <style>
        body {
            color: \(theme.colors.onBackground.toHTMLHex());
            font-family: Helvetica;
        }
        a {
            color: \(theme.colors.primary.toHTMLHex());
        }
        code, pre {
            font-family: Menlo;
            background: \(theme.colors.secondary.opacity(theme.colors.isLight ? 0.2 : 0.3).toHTMLHex());
        }
        </style>
        """
        let head = "<head><meta name='viewport' content='width=device-width, initial-scale=1.0, minimum-scale=1.0, user-scalable=no'>\(styles)</head>"
        webView.loadHTMLString(head + html, baseURL: nil)
        DispatchQueue.main.async {
            pageLoaded = true
        }
    }

    func makeCoordinator() -> Cordinator {
        Cordinator()
    }

    class Cordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

            guard let url = navigationAction.request.url else { return decisionHandler(.allow) }

            switch navigationAction.navigationType {
            case .linkActivated:
                decisionHandler(.cancel)
                if url.absoluteString.starts(with: "https://inqalaab.chat/contact#") || url.absoluteString.starts(with: "https://example.net/contact#") {
                    ChatModel.shared.appOpenUrl = url
                } else {
                    UIApplication.shared.open(url)
                }
            default:
                decisionHandler(.allow)
            }
        }
    }
}

struct NetworkServersView_Previews: PreviewProvider {
    static var previews: some View {
        NetworkAndServers()
    }
}
