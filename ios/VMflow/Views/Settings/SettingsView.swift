import SwiftUI

/// App settings with notification preferences, deal search, and account management.
struct SettingsView: View {
    @EnvironmentObject private var auth: AuthService
    @StateObject private var notifications = NotificationService.shared
    @StateObject private var deals = DealsViewModel()
    @State private var isSendingTest = false
    @State private var showSignOutConfirm = false

    var body: some View {
        List {
            // MARK: - Push Notifications Section
            Section {
                pushToggle
                if notifications.isEnabled {
                    notificationTypeToggles
                    testButton
                }
            } header: {
                Label("Push Notifications", systemImage: "bell.fill")
            } footer: {
                if notifications.permissionStatus == .denied {
                    Text("Notifications are disabled in system settings. Open Settings to enable them.")
                        .foregroundStyle(.orange)
                }
            }

            // MARK: - Deals Section
            Section {
                Toggle(isOn: Binding(
                    get: { deals.dealsEnabled },
                    set: { newValue in
                        deals.dealsEnabled = newValue
                        Task { await deals.saveSettings() }
                    }
                )) {
                    HStack(spacing: 12) {
                        Image(systemName: "tag.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 28)
                        Text("Enable Deal Search")
                    }
                }

                if deals.dealsEnabled {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 28)

                        Text("ZIP Code")

                        Spacer()

                        TextField("e.g. 60487", text: $deals.dealsZipCode)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .frame(maxWidth: 120)
                            .onSubmit {
                                Task { await deals.saveSettings() }
                            }
                    }
                }
            } header: {
                Label("Deals", systemImage: "tag.fill")
            } footer: {
                Text("Automatically find retailer offers matching your products based on your ZIP code.")
            }

            // MARK: - Account Section
            Section {
                if let org = auth.organization {
                    HStack {
                        Text("Organization")
                        Spacer()
                        Text(org.name)
                            .foregroundStyle(.secondary)
                    }
                }
                if let role = auth.role {
                    HStack {
                        Text("Role")
                        Spacer()
                        Text(role.rawValue.capitalized)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Account", systemImage: "person.fill")
            }

            // MARK: - Sign Out
            Section {
                Button(role: .destructive) {
                    showSignOutConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Sign Out")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .task {
            await notifications.checkPermissionStatus()
            if notifications.isEnabled {
                await notifications.fetchPreferences()
            }
            await deals.loadSettings()
        }
        .alert("Sign Out", isPresented: $showSignOutConfirm) {
            Button("Sign Out", role: .destructive) {
                Task {
                    await notifications.cleanupOnLogout()
                    await auth.logout()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to sign out?")
        }
        .alert("Error", isPresented: .init(
            get: { notifications.error != nil },
            set: { if !$0 { notifications.error = nil } }
        )) {
            Button("OK") { notifications.error = nil }
        } message: {
            Text(notifications.error ?? "")
        }
    }

    // MARK: - Push Toggle

    private var pushToggle: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge.fill")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Enable Notifications")
                    .font(.body)
                if notifications.isRegistering {
                    Text("Registering...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if notifications.permissionStatus == .denied {
                // Permission denied — link to Settings
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Toggle("", isOn: Binding(
                    get: { notifications.isEnabled },
                    set: { newValue in
                        Task {
                            if newValue {
                                let granted = await notifications.requestPermission()
                                if granted {
                                    await notifications.fetchPreferences()
                                }
                            } else {
                                await notifications.unregisterDevice()
                            }
                        }
                    }
                ))
                .labelsHidden()
            }
        }
    }

    // MARK: - Notification Type Toggles

    private var notificationTypeToggles: some View {
        ForEach(NotificationService.notificationTypes) { type in
            HStack(spacing: 12) {
                Image(systemName: type.icon)
                    .font(.body)
                    .foregroundStyle(notifications.isTypeEnabled(type.key) ? .orange : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(type.label)
                        .font(.body)
                    Text(type.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { notifications.isTypeEnabled(type.key) },
                    set: { newValue in
                        Task {
                            await notifications.togglePreference(type: type.key, enabled: newValue)
                        }
                    }
                ))
                .labelsHidden()
            }
        }
    }

    // MARK: - Test Button

    private var testButton: some View {
        Button {
            Task {
                isSendingTest = true
                await notifications.sendTestNotification()
                isSendingTest = false
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "paperplane.fill")
                    .font(.body)
                    .foregroundStyle(.green)
                    .frame(width: 28)

                Text("Send Test Notification")

                Spacer()

                if isSendingTest {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .disabled(isSendingTest)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AuthService())
    }
}
