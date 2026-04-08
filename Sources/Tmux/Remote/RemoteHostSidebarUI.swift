// RemoteHostSidebarUI.swift
// SwiftUI affordances for managing remote hosts: "+ Add remote host…"
// button, the add-host sheet with manual entry + SSH config picker,
// and helper views for status/context-menu wiring.
//
// Part of feature 708-remote-workspace-ssh (Phase 6, US4).
// Complies with FR-022 (immediate connect on add) and FR-023
// (SSH config filter is applied by SSHConfigParser, not here).

import SwiftUI

// MARK: - Add-host affordance

/// The "+ Add remote host" button shown in the sidebar's remote
/// section header. Taps present the `AddRemoteHostSheet` modal.
struct AddRemoteHostButton: View {
    @State private var isSheetPresented = false

    var body: some View {
        Button(action: { isSheetPresented = true }) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(String(localized: "remote.sidebar.addHost",
                            defaultValue: "Add remote host…"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isSheetPresented) {
            AddRemoteHostSheet(isPresented: $isSheetPresented)
        }
    }
}

// MARK: - Add-host sheet

enum AddRemoteHostMode: String, Hashable {
    case manual
    case fromConfig
}

struct AddRemoteHostSheet: View {
    @Binding var isPresented: Bool
    @State private var mode: AddRemoteHostMode = .manual
    @State private var destinationInput: String = ""
    @State private var aliasInput: String = ""
    @State private var errorMessage: String?
    @State private var isConnecting: Bool = false
    @State private var configHosts: [ParsedSSHHost] = []
    @State private var configHostsLoaded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "remote.sidebar.addHost.title",
                        defaultValue: "Add remote host"))
                .font(.headline)

            Picker("", selection: $mode) {
                Text(String(localized: "remote.sidebar.addHost.manual",
                            defaultValue: "Type destination"))
                    .tag(AddRemoteHostMode.manual)
                Text(String(localized: "remote.sidebar.addHost.fromConfig",
                            defaultValue: "From SSH config"))
                    .tag(AddRemoteHostMode.fromConfig)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch mode {
                case .manual:
                    manualEntrySection
                case .fromConfig:
                    configPickerSection
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(String(localized: "common.cancel",
                              defaultValue: "Cancel")) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if mode == .fromConfig && !configHostsLoaded {
                loadConfigHosts()
            }
        }
        .onChange(of: mode) { newMode in
            if newMode == .fromConfig && !configHostsLoaded {
                loadConfigHosts()
            }
        }
    }

    // MARK: - Manual entry

    private var manualEntrySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "remote.sidebar.addHost.destinationLabel",
                        defaultValue: "Destination"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextField("user@host", text: $destinationInput)
                .textFieldStyle(.roundedBorder)
                .disabled(isConnecting)
                .onSubmit(handleManualSubmit)

            Text(String(localized: "remote.sidebar.addHost.aliasLabel",
                        defaultValue: "Alias (optional)"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextField("", text: $aliasInput, prompt: Text(String(
                localized: "remote.sidebar.addHost.aliasPlaceholder",
                defaultValue: "Leave blank for default"
            )))
                .textFieldStyle(.roundedBorder)
                .disabled(isConnecting)
                .onSubmit(handleManualSubmit)

            HStack {
                Spacer()
                if isConnecting {
                    ProgressView()
                        .scaleEffect(0.6)
                        .padding(.trailing, 4)
                }
                Button(String(localized: "remote.sidebar.addHost.submit",
                              defaultValue: "Add & connect")) {
                    handleManualSubmit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting || destinationInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func handleManualSubmit() {
        let trimmedDest = destinationInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDest.isEmpty else { return }
        let trimmedAlias = aliasInput.trimmingCharacters(in: .whitespacesAndNewlines)
        addAndConnect(destination: trimmedDest, alias: trimmedAlias.isEmpty ? nil : trimmedAlias)
    }

    // MARK: - SSH config picker

    private var configPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "remote.sidebar.addHost.fromConfigHint",
                        defaultValue: "Hosts from ~/.ssh/config"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if configHosts.isEmpty {
                Text(String(localized: "remote.sidebar.addHost.fromConfigEmpty",
                            defaultValue: "No eligible hosts found in ~/.ssh/config"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(configHosts.enumerated()), id: \.offset) { _, host in
                            Button(action: {
                                addAndConnect(
                                    destination: host.suggestedDestination,
                                    alias: host.pattern
                                )
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "network")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .frame(width: 12)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(host.pattern)
                                            .font(.system(size: 12, weight: .medium))
                                        if let hostname = host.hostname {
                                            Text(hostname)
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .disabled(isConnecting)
                        }
                    }
                }
                .frame(maxHeight: 240)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
            }
        }
    }

    private func loadConfigHosts() {
        configHosts = SSHConfigParser.parse()
        configHostsLoaded = true
    }

    // MARK: - Add & connect

    private func addAndConnect(destination: String, alias: String?) {
        errorMessage = nil
        isConnecting = true
        let manager = RemoteHostManager.shared
        let host = manager.addHost(destination: destination, alias: alias)
        manager.connect(id: host.id) { result in
            isConnecting = false
            switch result {
            case .success:
                isPresented = false
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Status indicator

/// Small ● / ○ indicator reflecting a connection's current state.
struct RemoteConnectionStatusIndicator: View {
    let state: ConnectionState

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: 7))
            .foregroundColor(color)
            .frame(width: 10)
    }

    private var iconName: String {
        switch state {
        case .connected: return "circle.fill"
        case .connecting: return "circle.dotted"
        case .disconnected: return "circle"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }
}
