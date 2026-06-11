import SwiftUI
import ServiceManagement

/// Editable model wrapper so passwords can be edited alongside share configs.
private struct EditableShare: Identifiable {
    var config: ShareConfig
    var password: String
    var id: UUID { config.id }
}

struct SettingsView: View {
    @State private var shares: [EditableShare] = []
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var saveConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Network Shares")
                .font(.title2.bold())
            Text("Each share is kept mounted automatically: at login, after waking from sleep, and whenever the network reconnects.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if shares.isEmpty {
                ContentUnavailableView(
                    "No shares configured",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("Click “Add Share” to add your first NAS share.")
                )
                .frame(maxHeight: 220)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($shares) { $share in
                            ShareRowView(share: $share) {
                                remove(share)
                            }
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 380)
            }

            HStack {
                Button {
                    shares.append(EditableShare(config: ShareConfig(), password: ""))
                } label: {
                    Label("Add Share", systemImage: "plus")
                }
                Spacer()
            }

            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    setLaunchAtLogin(enabled)
                }

            HStack {
                Spacer()
                if saveConfirmation {
                    Text("Saved")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Button("Save & Mount") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: load)
    }

    private func load() {
        shares = ShareStore.shared.shares.map {
            EditableShare(config: $0, password: Keychain.password(for: $0.id) ?? "")
        }
    }

    private func save() {
        for share in shares {
            if share.password.isEmpty {
                Keychain.deletePassword(for: share.config.id)
            } else {
                Keychain.setPassword(share.password, for: share.config.id)
            }
        }
        ShareStore.shared.save(shares.map(\.config))
        MountManager.shared.mountAllIfNeeded(reason: "settings saved")

        withAnimation { saveConfirmation = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { saveConfirmation = false }
        }
    }

    private func remove(_ share: EditableShare) {
        Keychain.deletePassword(for: share.config.id)
        shares.removeAll { $0.id == share.id }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("NASMounter: launch-at-login change failed: \(error.localizedDescription)")
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}

/// One configured share. Owns the per-row share-discovery state so browsing
/// one server never affects another row.
private struct ShareRowView: View {
    @Binding var share: EditableShare
    let onRemove: () -> Void

    @State private var isDiscovering = false
    @State private var discoveredShares: [String] = []
    @State private var discoveryError: String?
    @State private var showSharePicker = false

    var body: some View {
        GroupBox {
            VStack(spacing: 8) {
                HStack {
                    Toggle("", isOn: $share.config.enabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                    Text(share.config.displayName.isEmpty ? "New Share" : share.config.displayName)
                        .font(.headline)
                    Spacer()
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Protocol")
                        Picker("", selection: $share.config.proto) {
                            ForEach(ShareProtocol.allCases) { proto in
                                Text(proto.displayName).tag(proto)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GridRow {
                        Text("Server")
                        TextField("nas.local or 192.168.1.10", text: $share.config.host)
                    }
                    GridRow {
                        Text("Share")
                        HStack(spacing: 6) {
                            TextField(share.config.proto.sharePlaceholder,
                                      text: $share.config.shareName)
                            if ShareDiscovery.supportsDiscovery(share.config.proto) {
                                browseButton
                            }
                        }
                    }
                    GridRow {
                        Text("Username")
                        TextField(usernamePlaceholder, text: $share.config.username)
                    }
                    GridRow {
                        Text("Password")
                        SecureField(passwordPlaceholder, text: $share.password)
                    }
                }
                .textFieldStyle(.roundedBorder)

                if let discoveryError {
                    Text(discoveryError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(4)
        }
    }

    /// Optional helper: queries the server for its shares and lets the user
    /// pick one. Typing the name directly always remains possible.
    private var browseButton: some View {
        Button {
            discoverShares()
        } label: {
            if isDiscovering {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "magnifyingglass")
            }
        }
        .buttonStyle(.borderless)
        .disabled(isDiscovering || share.config.host.trimmingCharacters(in: .whitespaces).isEmpty)
        .help(share.config.host.trimmingCharacters(in: .whitespaces).isEmpty
              ? "Enter a server first to browse its shares"
              : "Browse shares on \(share.config.host)")
        .popover(isPresented: $showSharePicker, arrowEdge: .bottom) {
            sharePicker
        }
    }

    private var sharePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Shares on \(share.config.host)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(discoveredShares, id: \.self) { name in
                        Button {
                            share.config.shareName = name
                            showSharePicker = false
                        } label: {
                            HStack {
                                Image(systemName: "externaldrive.connected.to.line.below")
                                    .foregroundStyle(.secondary)
                                Text(name)
                                Spacer()
                                if share.config.shareName == name {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 240)
        }
        .frame(minWidth: 220)
    }

    private func discoverShares() {
        discoveryError = nil
        isDiscovering = true
        let config = share.config
        let password = share.password
        Task {
            defer { isDiscovering = false }
            do {
                discoveredShares = try await ShareDiscovery.listShares(
                    host: config.host,
                    proto: config.proto,
                    username: config.username,
                    password: password
                )
                showSharePicker = true
            } catch {
                discoveryError = error.localizedDescription
            }
        }
    }

    private var usernamePlaceholder: String {
        share.config.proto == .nfs ? "Not needed for NFS" : "NAS username"
    }

    private var passwordPlaceholder: String {
        share.config.proto == .nfs ? "Not needed for NFS" : "Stored in Keychain"
    }
}
