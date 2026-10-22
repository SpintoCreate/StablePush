// Based on JJTech0130/ValidationRelay, ContentView.swift (James Gill, 2024).
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("autoConnect") private var wantRelayConnected = true
    @AppStorage("keepAwake") private var keepAwake = true
    @AppStorage("selectedRelay") private var selectedRelay = "Beeper"
    @AppStorage("customRelayURL") private var customRelayURL = ""
    @ObservedObject var relayConnectionManager: RelayConnectionManager
    @State private var started = false
    @State private var previousBrightness: CGFloat?
    @State private var confirmReset = false

    private func connect() {
        let raw = selectedRelay == "Custom" ? customRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
            : "wss://registration-relay.beeper.com/api/v1/provider"
        guard let url = URL(string: raw) else {
            relayConnectionManager.connectionStatusMessage = "Enter a valid wss:// relay URL"
            return
        }
        relayConnectionManager.connect(url)
    }

    private func updateAwake() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && wantRelayConnected && scenePhase == .active
        if scenePhase != .active || !keepAwake || !wantRelayConnected { restoreBrightness() }
    }

    private func restoreBrightness() {
        if let value = previousBrightness { UIScreen.main.brightness = value; previousBrightness = nil }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Toggle("Relay", isOn: $wantRelayConnected)
                        .onChange(of: wantRelayConnected) { enabled in
                            if enabled { connect() } else { relayConnectionManager.disconnect() }
                            updateAwake()
                        }
                    HStack {
                        Text("Pairing Code")
                        Spacer()
                        Text(relayConnectionManager.registrationCode)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .privacySensitive()
                    }
                    Text(relayConnectionManager.connectionStatusMessage).font(.footnote)
                } header: { Text("Provider connection") } footer: {
                    Text("Enter the code in OpenBubbles on Android. Pairing and validation delivery do not prove Apple registration succeeded. Do not share screenshots of the code.")
                }
                Section {
                    Picker("Relay", selection: $selectedRelay) {
                        Text("Beeper").tag("Beeper")
                        Text("Custom").tag("Custom")
                    }.pickerStyle(.segmented)
                    .onChange(of: selectedRelay) { _ in wantRelayConnected = false }
                    if selectedRelay == "Custom" {
                        TextField("wss://host/api/v1/provider", text: $customRelayURL)
                            .keyboardType(.URL)
                            .disableAutocorrection(true)
                            .autocapitalization(.none)
                            .disabled(wantRelayConnected)
                    }
                } header: { Text("Relay settings") } footer: { Text("Uses the existing relay service. Custom endpoints must use trusted TLS and the same provider protocol.") }
                Section {
                    Toggle("Keep Awake", isOn: $keepAwake)
                        .onChange(of: keepAwake) { _ in updateAwake() }
                    Button(previousBrightness == nil ? "Dim Display" : "Restore Display") {
                        if previousBrightness == nil {
                            previousBrightness = UIScreen.main.brightness
                            UIScreen.main.brightness = 0.05
                        } else { restoreBrightness() }
                    }.disabled(!keepAwake || !wantRelayConnected)
                    NavigationLink("Redacted Diagnostics", destination: LogView(logItems: relayConnectionManager.logItems))
                    Button("Reset Pairing", role: .destructive) { confirmReset = true }
                } header: { Text("Availability and diagnostics") } footer: {
                    Text("Leave this app open, unlocked and plugged in for validation and later renewal. Backgrounding or locking can suspend it. TrollStore does not guarantee background execution. Android performs Apple activation and schedules renewal; their results are not visible here.")
                }
            }
            .listStyle(.grouped)
            .navigationTitle("Validation Relay")
            .alert("Reset pairing?", isPresented: $confirmReset) {
                Button("Reset", role: .destructive) {
                    wantRelayConnected = false
                    relayConnectionManager.resetPairing()
                }
                Button("Cancel", role: .cancel) { }
            } message: { Text("You will need to enter a new code in OpenBubbles. This does not change your iPhone hardware identity.") }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            if !started {
                started = true
                if wantRelayConnected { connect() }
            }
            updateAwake()
        }
        .onChange(of: scenePhase) { phase in
            relayConnectionManager.setForeground(phase == .active)
            updateAwake()
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; restoreBrightness() }
    }
}
