import AppKit
import GameController
import SwiftUI
import MSIScreenCore

struct GameControllersView: View {
    @State private var snapshot: GameControllerSnapshot?
    @State private var error: String?
    @State private var reading = false
    @State private var testTask: Task<Void, Never>?
    @State private var testResult: GameControllerProbeResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "gamecontroller").font(.system(size: 26)).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Game controllers").font(.system(size: 14, weight: .semibold))
                    Text("This Mac · Bluetooth & USB").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await refresh() } }
                    .disabled(reading || testTask != nil)
                    .accessibilityLabel("Refresh game controllers")
                    .accessibilityIdentifier("refresh-game-controllers")
            }
            if let snapshot {
                if snapshot.devices.isEmpty && snapshot.profiles.isEmpty {
                    Text("No controller detected on this Mac.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snapshot.devices) { device in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name).font(.caption.weight(.semibold))
                        Text("\(device.transport) · \(device.supportedByMacOS ? "Recognized by macOS" : "Connected · game mode unsupported")")
                            .font(.caption2).foregroundStyle(device.supportedByMacOS ? .green : .orange)
                    }
                }
                ForEach(snapshot.profiles) { profile in
                    DisclosureGroup("\(profile.name) · controls & mappings") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Profile: \(profile.category)")
                            Text(profile.batteryPercent.map { "Battery: \($0)%" } ?? "Battery: not reported")
                            Text("Sticks / D-pad: " + profile.directionPads.joined(separator: ", "))
                            ForEach(profile.buttons, id: \.self) { name in
                                HStack {
                                    Text(name)
                                    Spacer()
                                    Text(profile.mappings[name] ?? name).foregroundStyle(.secondary)
                                }
                            }
                            Text("Reported support: " + [
                                profile.supportsMotion ? "motion" : nil,
                                profile.supportsHaptics ? "vibration" : nil,
                                profile.supportsLight ? "light" : nil
                            ].compactMap { $0 }.joined(separator: ", "))
                        }
                        .font(.caption2).padding(.top, 6)
                    }
                    .font(.caption)
                }
                HStack {
                    Button(testTask == nil ? "Test controls · 10s" : "Stop test") {
                        if let testTask { testTask.cancel() }
                        else {
                            testResult = nil
                            error = nil
                            testTask = Task {
                                defer { testTask = nil }
                                do { testResult = try await GameControllerClient.probe(seconds: 10) }
                                catch is CancellationError {}
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                    .disabled(snapshot.profiles.isEmpty)
                    .accessibilityIdentifier("test-game-controller")
                    if testTask != nil { ProgressView().controlSize(.mini) }
                }
                if testTask != nil {
                    Text("Press buttons and move both sticks. Listening for 10 seconds…")
                        .font(.caption2).foregroundStyle(.mint)
                } else if let testResult {
                    let count = testResult.changesByControl.values.reduce(0, +)
                    Text(count == 0 ? "No input observed. This test is inconclusive."
                         : "\(count) changes across \(testResult.changesByControl.count) controls.")
                        .font(.caption2).foregroundStyle(count == 0 ? .orange : .green)
                        .accessibilityIdentifier("game-controller-test-result")
                }
            } else if reading {
                ProgressView().controlSize(.small)
            }
            if let error { Text(error).font(.caption2).foregroundStyle(.orange) }
            HStack {
                Button("Customize in macOS…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Game-Controller-Settings.extension")!)
                }
                .accessibilityIdentifier("game-controller-settings")
                Button("Bluetooth…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                }
            }.controlSize(.small)
            Text("Bluetooth stays with its paired Mac when you switch the monitor’s USB host.")
                .font(.caption2).foregroundStyle(.secondary)
            DisclosureGroup("BSP-D8 connection modes") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Yellow: Android mode. For Xbox mode, power off, then hold RB + Home for 2 seconds. Pair “Xbox Wireless Controller” when the light flashes cyan.")
                    Link("D8 manual", destination: URL(string: "https://manuals.plus/m/cb5c51d89dc614d945421230e99b5b8a426413cc951478aa6d82794bfc550580.pdf")!)
                }.font(.caption2).padding(.top, 5)
            }.font(.caption)
        }
        .monitorCard(tint: .mint, inset: 12)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            let running = testTask
            running?.cancel()
            Task { await running?.value; await refresh() }
        }
        .onDisappear { testTask?.cancel() }
    }

    @MainActor
    private func refresh() async {
        guard !reading, testTask == nil else { return }
        reading = true
        defer { reading = false }
        do { snapshot = try await GameControllerClient.read(); error = nil }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}
