import SwiftUI

enum DataSource: String, CaseIterable {
    case xdrip = "xDrip+ Local API"
    case dexcomShare = "Dexcom Share Follower"
}

struct SettingsView: View {
    @AppStorage("GlucoseBarDataSource") private var dataSource: String = DataSource.xdrip.rawValue
    @AppStorage("GlucoseBarApiURL") private var apiURL: String = ""
    @AppStorage("DexcomShareUsername") private var dexcomUsername: String = ""
    @AppStorage("DexcomShareRegion") private var dexcomRegion: String = "us"

    @State private var secretField: String = ""
    @State private var dexcomPasswordField: String = ""
    @State private var secretSaved: Bool = false
    @State private var dexcomPasswordSaved: Bool = false
    @State private var message: String = ""
    @State private var messageType: MessageType = .info
    @State private var isTesting: Bool = false

    private let keychainService = Bundle.main.bundleIdentifier ?? "com.yourapp.GlucoseBar"
    private let secretAccount = "xDripApiSecret"
    private let dexcomPasswordAccount = "DexcomSharePassword"

    enum MessageType {
        case success, error, info

        var color: Color {
            switch self {
            case .success: return .green
            case .error: return .red
            case .info: return .blue
            }
        }

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error: return "xmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }
    }

    private var selectedDataSource: DataSource {
        DataSource(rawValue: dataSource) ?? .xdrip
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Data Source", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Picker("", selection: $dataSource) {
                        ForEach(DataSource.allCases, id: \.rawValue) { source in
                            Text(source.rawValue).tag(source.rawValue)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .onChange(of: dataSource) {
                        message = ""
                    }
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)

                if selectedDataSource == .xdrip {
                    xDripSettingsView
                } else {
                    dexcomShareSettingsView
                }

                if !message.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: messageType.icon)
                            .foregroundColor(messageType.color)
                            .font(.system(size: 16))

                        Text(message)
                            .font(.system(size: 13))
                            .foregroundColor(.primary)

                        Spacer()

                        Button(action: { message = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 14))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(12)
                    .background(messageType.color.opacity(0.1))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(messageType.color.opacity(0.3), lineWidth: 1)
                    )
                }

                Button(action: testConnection) {
                    HStack {
                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "network")
                        }
                        Text(isTesting ? "Testing Connection..." : "Test Connection")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(canTest && !isTesting ? Color.accentColor : Color.gray.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!canTest || isTesting)
                .shadow(color: canTest && !isTesting ? Color.accentColor.opacity(0.3) : Color.clear, radius: 8, y: 4)

                VStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("Made for the T1D community")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 16) {
                        Link(destination: URL(string: "https://github.com/heyimnel/GlucoseBar")!) {
                            Image("github-icon")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())

                        Link(destination: URL(string: "https://codeberg.org/heyimnel/GlucoseBar")!) {
                            Image("codeberg-icon")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 10)

            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
        }
        .frame(minWidth: 520, minHeight: 525)
        .onAppear {
            loadSecretState()
            loadDexcomPasswordState()
        }
    }

    private var canTest: Bool {
        if selectedDataSource == .xdrip {
            return !apiURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            return !dexcomUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && dexcomPasswordSaved
        }
    }

    private var xDripSettingsView: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Endpoint", systemImage: "network")
                    .font(.headline)
                    .foregroundColor(.primary)

                TextField("http://192.168.x.y:17580/sgv.json", text: $apiURL)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)

            VStack(alignment: .leading, spacing: 12) {
                Label("API Secret (Optional)", systemImage: "key.fill")
                    .font(.headline)
                    .foregroundColor(.primary)

                HStack(spacing: 0) {
                    SecureField(secretSaved ? "••••••••••••" : "Optional", text: $secretField)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor))
                        .disabled(secretSaved)

                    if secretSaved {
                        Button(action: {
                            withAnimation {
                                clearSecret()
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 12)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )

                if !secretSaved {
                    Button(action: saveSecret) {
                        HStack {
                            Image(systemName: "lock.fill")
                            Text("Save Secret")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(secretField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.3) : Color.accentColor)
                        .cornerRadius(6)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(secretField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)
        }
    }


    private var dexcomShareSettingsView: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Dexcom Account", systemImage: "person.circle.fill")
                    .font(.headline)
                    .foregroundColor(.primary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Username or Email")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("your.email@example.com", text: $dexcomUsername)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Password")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 0) {
                        SecureField(dexcomPasswordSaved ? "••••••••••••" : "Your password", text: $dexcomPasswordField)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(Color(nsColor: .textBackgroundColor))
                            .disabled(dexcomPasswordSaved)

                        if dexcomPasswordSaved {
                            Button(action: {
                                withAnimation {
                                    clearDexcomPassword()
                                }
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 12)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                }

                if !dexcomPasswordSaved {
                    Button(action: saveDexcomPassword) {
                        HStack {
                            Image(systemName: "lock.fill")
                            Text("Save Password")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(dexcomPasswordField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.3) : Color.accentColor)
                        .cornerRadius(6)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(dexcomPasswordField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Region")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("", selection: $dexcomRegion) {
                        Label {
                            Text("United States")
                        } icon: {
                            Text("🇺🇸")
                        }.tag("us")

                        Label {
                            Text("Outside US")
                        } icon: {
                            Text("🌍")
                        }.tag("ous")

                        Label {
                            Text("Japan")
                        } icon: {
                            Text("🇯🇵")
                        }.tag("jp")
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .offset(x: -6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)
        }
    }


    private func saveSecret() {
        let s = secretField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else {
            showMessage("Secret is empty.", type: .error)
            return
        }

        do {
            try Keychain.save(secret: s, account: secretAccount, service: keychainService)
            secretField = ""
            secretSaved = true
            showMessage("API secret saved securely.", type: .success)
        } catch {
            showMessage("Failed to save secret.", type: .error)
        }
    }

    private func clearSecret() {
        do {
            try Keychain.delete(account: secretAccount, service: keychainService)
            secretSaved = false
            showMessage("API secret cleared.", type: .info)
        } catch {
            showMessage("Failed to clear secret.", type: .error)
        }
    }

    private func loadSecretState() {
        do {
            _ = try Keychain.load(account: secretAccount, service: keychainService)
            secretSaved = true
        } catch {
            secretSaved = false
        }
    }


    private func saveDexcomPassword() {
        let p = dexcomPasswordField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else {
            showMessage("Password is empty.", type: .error)
            return
        }

        do {
            try Keychain.save(secret: p, account: dexcomPasswordAccount, service: keychainService)
            dexcomPasswordField = ""
            dexcomPasswordSaved = true
            showMessage("Password saved securely.", type: .success)
        } catch {
            showMessage("Failed to save password.", type: .error)
        }
    }

    private func clearDexcomPassword() {
        do {
            try Keychain.delete(account: dexcomPasswordAccount, service: keychainService)
            dexcomPasswordSaved = false
            showMessage("Password cleared.", type: .info)
        } catch {
            showMessage("Failed to clear password.", type: .error)
        }
    }

    private func loadDexcomPasswordState() {
        do {
            _ = try Keychain.load(account: dexcomPasswordAccount, service: keychainService)
            dexcomPasswordSaved = true
        } catch {
            dexcomPasswordSaved = false
        }
    }


    private func showMessage(_ text: String, type: MessageType) {
        withAnimation {
            message = text
            messageType = type
        }
    }


    private func testConnection() {
        isTesting = true
        message = ""

        if selectedDataSource == .xdrip {
            testXDripConnection()
        } else {
            testDexcomShareConnection()
        }
    }

    private func testXDripConnection() {
        let urlString = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString) else {
            showMessage("Invalid URL format.", type: .error)
            isTesting = false
            return
        }

        var apiSecret: String?
        do { apiSecret = try Keychain.load(account: secretAccount, service: keychainService) }
        catch { apiSecret = nil }

        var request = URLRequest(url: url, timeoutInterval: 10)
        if let s = apiSecret { request.setValue(s.sha1Hex, forHTTPHeaderField: "api-secret") }

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                self.isTesting = false
                if let err = error as NSError? {
                    self.showMessage("Connection failed: \(err.localizedDescription)", type: .error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.showMessage("Invalid server response.", type: .error)
                    return
                }
                if 200..<300 ~= http.statusCode {
                    self.showMessage("✓ Connected successfully!", type: .success)
                } else {
                    self.showMessage("Server returned HTTP \(http.statusCode).", type: .error)
                }
            }
        }.resume()
    }

    private func testDexcomShareConnection() {
        let username = dexcomUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            showMessage("Username is required.", type: .error)
            isTesting = false
            return
        }

        guard let password = try? Keychain.load(account: dexcomPasswordAccount, service: keychainService) else {
            showMessage("Password not saved.", type: .error)
            isTesting = false
            return
        }

        let client = DexcomShareClient()

        Task {
            do {
                let reading = try await client.fetchLatestReading(
                    username: username,
                    password: password,
                    region: dexcomRegion
                )

                await MainActor.run {
                    self.isTesting = false
                    self.showMessage("✓ Connected! Latest: \(reading.value) mg/dL \(reading.direction)", type: .success)
                }
            } catch DexcomShareError.authenticationFailed {
                await MainActor.run {
                    self.isTesting = false
                    self.showMessage("Authentication failed. Check credentials.", type: .error)
                }
            } catch {
                await MainActor.run {
                    self.isTesting = false
                    self.showMessage("Connection failed: \(error.localizedDescription)", type: .error)
                }
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
