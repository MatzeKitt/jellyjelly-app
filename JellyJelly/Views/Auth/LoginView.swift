import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    private enum Step {
        case server
        case credentials
    }

    @State private var step = Step.server
    @State private var serverInput = ""
    @State private var serverURL: URL?
    @State private var serverInfo: PublicSystemInfo?
    @State private var publicUsers: [UserDto] = []
    @State private var quickConnectAvailable = false
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var quickConnectCode: String?
    @State private var quickConnectTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum Field {
        case server
        case username
        case password
    }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    AppMark(size: 72)
                    Text("JellyJelly")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                    Text(step == .server ? "Connect to your Jellyfin server" : "Sign in to \(serverInfo?.serverName ?? "Jellyfin")")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.secondaryText)
                }

                VStack(spacing: 16) {
                    switch step {
                    case .server:
                        serverForm
                    case .credentials:
                        credentialsForm
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0xFCA5A5))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(28)
                .frame(width: 420)
                .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .background(palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
            }
            .animation(.spring(response: 0.35), value: step)
        }
        .onAppear {
            serverInput = app.lastServerURL
            focusedField = .server
        }
        .onDisappear {
            quickConnectTask?.cancel()
        }
    }

    private var backdrop: some View {
        ZStack {
            palette.backgroundGradient
            Circle()
                .fill(palette.accent.opacity(0.22))
                .frame(width: 700)
                .blur(radius: 140)
                .offset(x: -320, y: -260)
            Circle()
                .fill(palette.accentDeep.opacity(0.18))
                .frame(width: 600)
                .blur(radius: 140)
                .offset(x: 380, y: 300)
        }
        .ignoresSafeArea()
    }

    // MARK: - Server

    private var serverForm: some View {
        VStack(spacing: 16) {
            LoginField(systemImage: "server.rack", placeholder: "https://jellyfin.example.com", text: $serverInput, contentType: .URL)
                .focused($focusedField, equals: .server)
                .onSubmit(connect)
            Button(action: connect) {
                HStack {
                    if busy {
                        ProgressView().controlSize(.small).tint(palette.onAccent)
                    }
                    Text("Connect")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(busy || serverInput.isEmpty)
        }
    }

    private func connect() {
        guard let url = JellyfinClient.normalizedServerURL(serverInput) else {
            error = APIError.invalidURL.localizedDescription
            return
        }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            let client = JellyfinClient(serverURL: url)
            do {
                let info = try await client.publicSystemInfo()
                serverURL = url
                serverInfo = info
                publicUsers = (try? await client.publicUsers()) ?? []
                quickConnectAvailable = await client.quickConnectEnabled()
                step = .credentials
                focusedField = .username
            } catch {
                self.error = String(localized: "Could not reach a Jellyfin server at \(url.host ?? serverInput). \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Credentials

    private var credentialsForm: some View {
        VStack(spacing: 16) {
            if let quickConnectCode {
                VStack(spacing: 10) {
                    Text("Enter this code in another signed-in Jellyfin app under Quick Connect:")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                    Text(quickConnectCode)
                        .font(.system(size: 40, weight: .heavy, design: .monospaced))
                        .tracking(8)
                        .foregroundStyle(palette.accent)
                        .textSelection(.enabled)
                    ProgressView().controlSize(.small)
                    Button("Cancel") {
                        quickConnectTask?.cancel()
                        self.quickConnectCode = nil
                    }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                }
            } else {
                if !publicUsers.isEmpty {
                    HStack(spacing: 18) {
                        ForEach(publicUsers) { user in
                            Button {
                                username = user.name ?? ""
                                focusedField = .password
                            } label: {
                                VStack(spacing: 6) {
                                    ChannelAvatar(url: user.primaryImageTag.flatMap { tag in serverURL.map { JellyfinClient(serverURL: $0).userImageURL(userId: user.id, tag: tag) } },
                                                  name: user.name, size: 54)
                                        .overlay(Circle().strokeBorder(palette.accent, lineWidth: username == user.name ? 2 : 0))
                                    Text(user.name ?? "")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(palette.secondaryText)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 4)
                }
                LoginField(systemImage: "person.fill", placeholder: String(localized: "Username"), text: $username, contentType: .username)
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }
                LoginField(systemImage: "lock.fill", placeholder: String(localized: "Password"), text: $password, secure: true, contentType: .password)
                    .focused($focusedField, equals: .password)
                    .onSubmit(signIn)
                Button(action: signIn) {
                    HStack {
                        if busy {
                            ProgressView().controlSize(.small).tint(palette.onAccent)
                        }
                        Text("Sign In")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(busy || username.isEmpty)

                HStack {
                    Button("Change Server") {
                        step = .server
                        error = nil
                    }
                    Spacer()
                    if quickConnectAvailable {
                        Button("Use Quick Connect", action: startQuickConnect)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.accent)
            }
        }
    }

    private func signIn() {
        guard let serverURL, !username.isEmpty else {
            return
        }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let result = try await JellyfinClient(serverURL: serverURL).authenticate(username: username, password: password)
                await app.completeSignIn(serverURL: serverURL, result: result)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func startQuickConnect() {
        guard let serverURL else {
            return
        }
        error = nil
        let client = JellyfinClient(serverURL: serverURL)
        quickConnectTask?.cancel()
        quickConnectTask = Task {
            do {
                let initial = try await client.quickConnectInitiate()
                guard let secret = initial.secret else {
                    return
                }
                quickConnectCode = initial.code
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    let state = try await client.quickConnectState(secret: secret)
                    if state.authenticated == true {
                        let result = try await client.authenticateWithQuickConnect(secret: secret)
                        await app.completeSignIn(serverURL: serverURL, result: result)
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                quickConnectCode = nil
                self.error = error.localizedDescription
            }
        }
    }
}

private struct LoginField: View {
    var systemImage: String
    var placeholder: String
    @Binding var text: String
    var secure = false
    var contentType: NSTextContentType?

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(palette.tertiaryText)
                .frame(width: 18)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .autocorrectionDisabled()
                }
            }
            .textFieldStyle(.plain)
            .textContentType(contentType)
            .font(.system(size: 15))
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }
}
