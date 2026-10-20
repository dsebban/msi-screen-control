import AppKit
import SwiftUI
import MSIScreenCore

struct MonitorView: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "display").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MSI Screen").font(.headline)
                    Text("Modern MD342CQP").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh monitor state")
                    .accessibilityLabel("Refresh monitor")
                    .disabled(store.busy)
            }

            layoutPreview
            if let current = store.currentLayout {
                Text(current).font(.caption).foregroundStyle(.secondary)
            }

            Picker("Layout", selection: $store.split) {
                Text("Full screen").tag(false)
                Text("Side by side").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("layout-mode")
            .disabled(store.busy || store.state == nil)

            VStack(spacing: 10) {
                inputPicker(store.split ? "Left input" : "Input", selection: $store.left)
                if store.split {
                    inputPicker("Right input", selection: $store.right)
                    Button("Swap sides", systemImage: "arrow.left.arrow.right") { store.swap() }
                        .accessibilityIdentifier("swap-sides")
                }
            }
            .disabled(store.busy || store.state == nil)

            if store.duplicateInputs {
                Label("Choose two different inputs.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error = store.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("monitor-error")
            }

            HStack(spacing: 8) {
                if store.busy { ProgressView().controlSize(.small) }
                Text(store.message).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("monitor-status")
                Spacer(minLength: 0)
            }

            Button(store.busy ? "Working…" : "Apply layout") { store.apply() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .controlSize(.large)
                .disabled(!store.canApply)
                .accessibilityIdentifier("apply-layout")

            Divider()
            HStack {
                Button("Copy CLI command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.command, forType: .string)
                }
                .disabled(store.state == nil || store.duplicateInputs || store.busy)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .disabled(store.busy)
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(20)
        .frame(width: 340)
    }

    private var layoutPreview: some View {
        HStack(spacing: 1) {
            previewPane(store.left.title, icon: "desktopcomputer")
            if store.split { previewPane(store.right.title, icon: "laptopcomputer") }
        }
        .frame(height: 78)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.secondary.opacity(0.25)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Proposed layout: \(store.left.title)\(store.split ? " left, \(store.right.title) right" : " full screen")")
    }

    private func previewPane(_ title: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.tint.opacity(0.08))
    }

    private func inputPicker(_ label: String, selection: Binding<Input>) -> some View {
        Picker(label, selection: selection) {
            ForEach(Input.allCases, id: \.self) { input in Text(input.title).tag(input) }
        }
    }
}
