// Based on JJTech0130/ValidationRelay (James Gill, 2024).
import SwiftUI

@main
struct ValidationRelayApp: App {
    @StateObject private var manager = RelayConnectionManager()
    var body: some Scene {
        WindowGroup { ContentView(relayConnectionManager: manager) }
    }
}
