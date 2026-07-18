import SwiftUI
import AppKit

/// SolStream Preferences window (SwiftUI).
///
/// Sections:
///   - Connection: server address, pair/re-pair button, status
///   - Display: windowed / fullscreen, frame rate
///   - Audio: device selector, volume
///   - About: version, build info
public struct PreferencesView: View {
    @State private var serverAddress: String = ""
    @State private var frameRate: Double = 60
    @State private var fullscreen: Bool = false
    @State private var audioVolume: Double = 1.0
    @State private var connectionStatus: String = "Disconnected"
    @State private var appVersion: String = "0.2.0"

    private let defaults = UserDefaults.standard

    public init() {
        // Load saved preferences.
        _serverAddress = State(initialValue: defaults.string(forKey: "serverAddress") ?? "")
        _frameRate = State(initialValue: defaults.double(forKey: "frameRate").nonzero ?? 60)
        _fullscreen = State(initialValue: defaults.bool(forKey: "fullscreen"))
        _audioVolume = State(initialValue: defaults.double(forKey: "audioVolume").nonzero ?? 1.0)
    }

    public var body: some View {
        TabView {
            connectionTab
            displayTab
            audioTab
            aboutTab
        }
        .padding()
        .frame(width: 480, height: 360)
    }

    // MARK: - Connection Tab

    private var connectionTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connection").font(.headline)

            HStack {
                Text("Server Address:")
                TextField("e.g. 192.168.1.100", text: $serverAddress)
                    .onChange(of: serverAddress) { _ in
                        defaults.set(serverAddress, forKey: "serverAddress")
                    }
            }

            HStack {
                Text("Status:")
                Text(connectionStatus)
                    .foregroundColor(connectionStatus == "Connected" ? .green : .secondary)
            }

            HStack(spacing: 12) {
                Button("Pair / Connect") {
                    connectToServer()
                }

                Button("Re-pair") {
                    KeychainStorage.clearAll()
                    connectionStatus = "Re-pairing..."
                }

                Button("Disconnect") {
                    disconnectFromServer()
                }
            }
        }
        .padding()
        .tabItem { Label("Connection", systemImage: "network") }
    }

    // MARK: - Display Tab

    private var displayTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Display").font(.headline)

            Toggle("Fullscreen on stream start", isOn: $fullscreen)
                .onChange(of: fullscreen) { _ in
                    defaults.set(fullscreen, forKey: "fullscreen")
                }

            VStack(alignment: .leading) {
                Text("Frame Rate: \(Int(frameRate)) FPS")
                Slider(value: $frameRate, in: 24...144, step: 1)
                    .onChange(of: frameRate) { _ in
                        defaults.set(frameRate, forKey: "frameRate")
                    }
            }
        }
        .padding()
        .tabItem { Label("Display", systemImage: "display") }
    }

    // MARK: - Audio Tab

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Audio").font(.headline)

            VStack(alignment: .leading) {
                Text("Volume: \(Int(audioVolume * 100))%")
                Slider(value: $audioVolume, in: 0...1, step: 0.05)
                    .onChange(of: audioVolume) { _ in
                        defaults.set(audioVolume, forKey: "audioVolume")
                    }
            }
        }
        .padding()
        .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SolStream").font(.title)
            Text("Remote App Streaming").foregroundColor(.secondary)

            Divider()

            Group {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: "2026.07")
                LabeledContent("Protocol", value: "Moonlight-compatible SRTP")
            }

            Divider()

            Text("© 2026 SolStream Contributors")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .tabItem { Label("About", systemImage: "info.circle") }
    }

    // MARK: - Actions

    private func connectToServer() {
        guard !serverAddress.isEmpty else {
            connectionStatus = "Enter a server address"
            return
        }

        // Check Keychain for stored credentials.
        if let creds = KeychainStorage.retrieve(host: serverAddress) {
            connectionStatus = "Found stored credentials — connecting..."
            _ = creds.token  // Use for WS auth
        } else {
            connectionStatus = "No stored credentials — pair with PIN"
        }
    }

    private func disconnectFromServer() {
        connectionStatus = "Disconnected"
    }
}

// MARK: - Preview

struct PreferencesView_Previews: PreviewProvider {
    static var previews: some View {
        PreferencesView()
    }
}

// MARK: - Helper

extension Double {
    /// Return self if non-zero, otherwise the provided fallback.
    var nonzero: Double { self == 0 ? 1.0 : self }
}
