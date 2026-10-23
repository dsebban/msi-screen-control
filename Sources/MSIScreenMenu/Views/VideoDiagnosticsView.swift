import SwiftUI
import MSIScreenCore

struct VideoDiagnosticsView: View {
    @ObservedObject var diagnostics: VideoDiagnosticsStore
    @State private var showingOtherModes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Connection & refresh rates", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Text("Read-only observations from this Mac. Monitoring never changes the display, wakes it or sends monitor commands.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(diagnostics.monitoring ? "Stop monitoring" : "Start monitoring") {
                        if diagnostics.monitoring { diagnostics.stop() } else { diagnostics.start() }
                    }
                    .accessibilityIdentifier("video-monitor-toggle")
                    Button("Refresh") { diagnostics.refresh() }.disabled(diagnostics.busy)
                        .accessibilityIdentifier("video-refresh")
                    Spacer()
                    Text(diagnostics.monitoring ? "Observing" : "Paused")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("video-monitor-state")
                }
                if let checked = diagnostics.snapshot?.checkedAt {
                    Text("Last read \(checked.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.monitorCard()

            if let snapshot = diagnostics.snapshot {
                if let error = snapshot.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                } else if snapshot.displays.isEmpty {
                    Text("No MSI video display detected by macOS.").font(.callout).monitorCard()
                }
                ForEach(snapshot.displays, id: \.display.id) { item in
                    displayCard(item, snapshot: snapshot)
                }
                if case .failed(_, let message) = snapshot.links.outcome {
                    Text("Port observations incomplete: \(message)").font(.caption).foregroundStyle(.orange)
                }
                if !snapshot.links.portStates.isEmpty {
                    DisclosureGroup("Local video ports") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("OS-reported ports, including inactive ones. A port observation alone does not identify the attached monitor.")
                                .font(.caption2).foregroundStyle(.secondary)
                            ForEach(Array(snapshot.links.portStates.enumerated()), id: \.offset) { _, port in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(port.hostPort).font(.caption.weight(.semibold))
                                    detail("Link", port.active ? "Active" : "Inactive")
                                    detail("Reported rate", port.linkRateDescription ?? "Not reported")
                                    detail("Driver", port.driverStatus ?? "Not reported")
                                    detail("Hot plug", port.hotPlugStatus ?? "Not reported")
                                }
                            }
                        }.padding(.top, 8)
                    }.font(.caption).monitorCard()
                }
            } else {
                Text(diagnostics.busy ? "Reading video connection…" : "Refresh to read the current connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            historyCard
            Text("Physical static, signal-error counters and individual link-training failures are not measured. Lane-count codes are not decoded. A quiet event history does not prove a stable picture; brief changes between samples can be missed.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { if diagnostics.snapshot == nil { diagnostics.refresh() } }
    }

    private func displayCard(_ item: VideoDisplayDiagnostics, snapshot: VideoDiagnosticsSnapshot) -> some View {
        let current = item.display.mode
        let connection = snapshot.connection(for: item.display)
        let port = connection.flatMap { link in snapshot.links.portStates.first { $0.hostPort == link.hostPort } }
        let currentModes = item.modes.filter { $0.width == current?.width && $0.height == current?.height
            && $0.pixelWidth == current?.pixelWidth && $0.pixelHeight == current?.pixelHeight }
        return VStack(alignment: .leading, spacing: 10) {
            Text("MSI MD342CQP").font(.subheadline.weight(.semibold))
            if let current {
                Text("\(current.width) × \(current.height) · \(rate(current.refreshRate))")
                    .font(.title3.weight(.semibold)).monospacedDigit()
                    .accessibilityIdentifier("video-current-mode")
            }
            detail("Connection", connection.map { transportName($0.transport) } ?? "Not uniquely identified")
            if let port {
                detail("Mac port", port.hostPort)
                detail("Reported link rate", port.linkRateDescription ?? "Not reported")
                detail("Driver / hot plug", "\(port.driverStatus ?? "Unknown") / \(port.hotPlugStatus ?? "Unknown")")
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("Available at this resolution").font(.caption.weight(.semibold))
                Text(rates(currentModes)).font(.callout).monospacedDigit()
                    .accessibilityIdentifier("video-current-rates")
                Text("Choices macOS currently offers, not the monitor’s maximum specification. A reported link rate is not measured throughput.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            DisclosureGroup("All available modes", isExpanded: $showingOtherModes) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(modeGroups(item.modes), id: \.key) { group in
                        detail(group.key, rates(group.value))
                    }
                }.padding(.top, 7)
            }.font(.caption).accessibilityIdentifier("video-all-modes")
        }.monitorCard()
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Observed changes").font(.subheadline.weight(.semibold))
            if let start = diagnostics.history.startedAt {
                Text("\(diagnostics.history.changeCount) changes since \(start.formatted(date: .omitted, time: .standard))")
                    .font(.caption).accessibilityIdentifier("video-change-count")
                Text("Every 2 seconds and on macOS display notifications. History is kept for this session only, up to 100 events.")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(diagnostics.history.events.reversed()) { event in
                    HStack(alignment: .top) {
                        Text(event.date.formatted(date: .omitted, time: .standard)).monospacedDigit()
                        Text(event.message).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption2)
                }
            } else {
                Text("Start monitoring to record connection, mode, refresh-option and local port changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.monitorCard()
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }.font(.caption)
    }

    private func rate(_ value: Double) -> String {
        value == 0 ? "Not reported" : value.formatted(.number.precision(.fractionLength(0...2))) + " Hz"
    }
    private func rates(_ modes: [VideoModeCapability]) -> String {
        let values = Set(modes.map(\.refreshRate)).sorted()
        return values.isEmpty ? "Not reported" : values.map(rate).joined(separator: ", ")
    }
    private func modeGroups(_ modes: [VideoModeCapability]) -> [(key: String, value: [VideoModeCapability])] {
        Dictionary(grouping: modes) { mode in
            let scaled = mode.pixelWidth != mode.width || mode.pixelHeight != mode.height
            return "\(mode.width) × \(mode.height)" + (scaled ? " (\(mode.pixelWidth) × \(mode.pixelHeight) pixels)" : "")
        }.map { (key: $0.key, value: $0.value) }.sorted {
            if $0.value[0].width != $1.value[0].width { return $0.value[0].width > $1.value[0].width }
            return $0.key < $1.key
        }
    }
    private func transportName(_ transport: VideoTransport) -> String {
        switch transport {
        case .usbc: return "USB-C"
        case .hdmi: return "HDMI"
        case .displayPort: return "DisplayPort"
        case .unknown: return "Unknown"
        }
    }
}
