import SwiftUI

/// Linked devices (Telegram's Active Sessions): this device, computers, phones; sign out one or all others.
struct DevicesView: View {
    @Environment(CrokEngine.self) private var engine
    @State private var selected: DeviceRow?
    @State private var confirmOthers = false
    @State private var actionError: RelayError?
    @State private var signedOutCount: Int?

    var body: some View {
        let devices = engine.deviceList.value ?? []
        let current = devices.filter(\.isCurrent)
        let computers = devices.filter { !$0.isCurrent && $0.kind == .computer }
        let phones = devices.filter { !$0.isCurrent && $0.kind != .computer }
        List {
            if !current.isEmpty {
                Section("This device") {
                    ForEach(current) { device in row(device) }
                }
            }
            Section {
                if computers.isEmpty {
                    Text("No computers yet. Run crok remote login on one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(computers) { device in row(device) }
                }
            } header: {
                Text("Computers")
            }
            if !phones.isEmpty {
                Section("Phones") {
                    ForEach(phones) { device in row(device) }
                }
            }
            if !computers.isEmpty || !phones.isEmpty {
                Section {
                    Button("Sign out all other devices", role: .destructive) { confirmOthers = true }
                        .accessibilityIdentifier("signOutOthers")
                } footer: {
                    Text("Every computer and phone except this iPhone is signed out. They can sign in again with a new code.")
                }
            }
        }
        .overlay {
            if engine.deviceList.value == nil { ProgressView() }
        }
        .navigationTitle("Devices")
        .sheet(item: $selected) { device in
            DeviceDetailSheet(device: device)
                .environment(engine)
        }
        .confirmationDialog("Sign out all other devices?", isPresented: $confirmOthers, titleVisibility: .visible) {
            Button("Sign out all other devices", role: .destructive) {
                Task { await signOutOthers() }
            }
        } message: {
            Text("Their sessions stop showing here until they sign in again.")
        }
        .alert(
            "Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }),
            presenting: actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
        .alert(
            "Signed out", isPresented: Binding(get: { signedOutCount != nil }, set: { if !$0 { signedOutCount = nil } }),
            presenting: signedOutCount
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { count in
            Text("\(count) devices were signed out.")
        }
    }

    private func signOutOthers() async {
        do {
            signedOutCount = try await engine.devices.revokeOthers()
        } catch {
            let relayError = (error as? RelayError) ?? RelayError(.server, error.localizedDescription)
            if relayError.isRevoked { engine.handleRevoked() } else { actionError = relayError }
        }
    }

    private func row(_ device: DeviceRow) -> some View {
        Button {
            selected = device
        } label: {
            DeviceRowView(device: device)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("deviceRow-\(device.name)")
    }
}

struct DeviceRowView: View {
    let device: DeviceRow

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: DeviceRowView.symbol(for: device))
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(
                    (device.kind == .computer ? Theme.accent : Color.blue).gradient,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text([device.platform, device.client].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if device.online || device.isCurrent {
                        Text("Online")
                            .font(.footnote)
                            .foregroundStyle(Theme.accent)
                    } else {
                        Text(RelativeTime.lastSeen(Date(milliseconds: device.lastSeenAt), now: context.date))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    static func symbol(for device: DeviceRow) -> String {
        let platform = device.platform.lowercased()
        switch device.kind {
        case .computer:
            return platform.contains("mac") ? "laptopcomputer" : "desktopcomputer"
        case .phone, .unknown:
            return platform.contains("ipad") ? "ipad" : "iphone"
        }
    }
}

/// One device's details and "Sign out this device".
struct DeviceDetailSheet: View {
    let device: DeviceRow
    @Environment(CrokEngine.self) private var engine
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false
    @State private var actionError: RelayError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DeviceRowView(device: device)
                }
                Section {
                    LabeledContent(
                        "Type", value: device.kind == .computer ? String(localized: "Computer") : String(localized: "Phone"))
                    LabeledContent("Platform", value: device.platform)
                    LabeledContent("App", value: device.client)
                    LabeledContent(
                        "Linked", value: Date(milliseconds: device.createdAt).formatted(date: .abbreviated, time: .shortened))
                    if device.kind == .computer {
                        LabeledContent("Running sessions", value: "\(Int(device.liveSessionCount))")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(role: .destructive) {
                    confirm = true
                } label: {
                    Text(device.isCurrent ? "Sign Out" : "Sign out this device")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(Theme.danger)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityIdentifier("signOutDevice")
            }
            .navigationTitle(device.kind == .computer ? "Computer" : "Phone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Sign out \(device.name)?", isPresented: $confirm, titleVisibility: .visible) {
                Button(device.isCurrent ? "Sign Out" : "Sign out this device", role: .destructive) {
                    Task { await signOut() }
                }
            } message: {
                Text(device.kind == .computer
                    ? String(localized: "Its sessions stop showing here and it can't take prompts until it signs in again.")
                    : String(localized: "It can sign in again with a new code."))
            }
            .alert(
                "Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }),
                presenting: actionError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error.message)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func signOut() async {
        if device.isCurrent {
            await app.signOut()
            return
        }
        let devicesAPI = engine.devices
        let id = device.id
        actionError = await engine.perform { try await devicesAPI.revoke(id) }
        if actionError == nil { dismiss() }
    }
}
