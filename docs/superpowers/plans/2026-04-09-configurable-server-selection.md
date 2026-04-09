# Configurable Server Selection — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iOS app's Supabase server configurable at runtime via a server selector on the login screen, with QR code scanning support and a companion page in the management frontend.

**Architecture:** New `ServerStore` service persists server entries in UserDefaults. `SupabaseService` gains a `reconfigure()` method. Three singleton services (`AuthService`, `RealtimeService`, `NotificationService`) change from captured `let client` to computed properties. Login screen gets a subtle server indicator that opens a bottom sheet for selection. A new fullscreen view handles adding/editing servers with QR scanning. The management frontend gets a `/mobile-app` page with QR code for self-hosted onboarding.

**Tech Stack:** SwiftUI, AVFoundation (QR scanning), UserDefaults, Supabase Swift SDK, Nuxt 4, `qrcode` npm package

**Spec:** `docs/superpowers/specs/2026-04-09-configurable-server-selection-design.md`

---

## Chunk 1: Data Model + ServerStore + SupabaseService Refactor

### Task 1: Create ServerEntry model

**Files:**
- Create: `ios/VMflow/Models/ServerEntry.swift`

- [ ] **Step 1: Create the ServerEntry model file**

```swift
import Foundation

/// A Supabase server configuration that can be persisted and selected by the user.
struct ServerEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var anonKey: String
    let isDefault: Bool

    /// Sanitize the URL by stripping trailing slashes.
    var sanitizedURL: String {
        var u = url
        while u.hasSuffix("/") { u = String(u.dropLast()) }
        return u
    }

    /// Validate that the URL is well-formed and has an http/https scheme.
    var isValid: Bool {
        guard !name.isEmpty, !url.isEmpty, !anonKey.isEmpty else { return false }
        guard let parsed = URL(string: sanitizedURL),
              let scheme = parsed.scheme,
              ["http", "https"].contains(scheme.lowercased()),
              parsed.host != nil else { return false }
        return true
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/VMflow/Models/ServerEntry.swift
git commit -m "feat(ios): add ServerEntry model for configurable server selection"
```

### Task 2: Create ServerStore service

**Files:**
- Create: `ios/VMflow/Services/ServerStore.swift`
- Reference: `ios/VMflow/Services/SupabaseService.swift:8-25` (AppConfig enum for default values)

- [ ] **Step 1: Create ServerStore**

```swift
import Foundation

/// Manages the list of configured Supabase servers, persisted in UserDefaults.
/// Always includes the built-in default server (from AppConfig/xcconfig).
@MainActor
final class ServerStore: ObservableObject {
    static let shared = ServerStore()

    private let serversKey = "savedServers"
    private let selectedKey = "selectedServerId"

    /// The default server entry, derived from build-time AppConfig values.
    let defaultServer: ServerEntry

    /// All saved custom (self-hosted) servers.
    @Published private(set) var customServers: [ServerEntry] = []

    /// All servers: default + custom.
    var allServers: [ServerEntry] {
        [defaultServer] + customServers
    }

    /// The currently selected server.
    var selectedServer: ServerEntry {
        if let idString = UserDefaults.standard.string(forKey: selectedKey),
           let id = UUID(uuidString: idString),
           let match = allServers.first(where: { $0.id == id }) {
            return match
        }
        return defaultServer
    }

    private init() {
        // Build default entry from xcconfig/Info.plist values
        defaultServer = ServerEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "VMflow Cloud",
            url: AppConfig.supabaseURL.absoluteString,
            anonKey: AppConfig.supabaseAnonKey,
            isDefault: true
        )
        loadCustomServers()
    }

    // MARK: - Selection

    func selectServer(_ server: ServerEntry) {
        UserDefaults.standard.set(server.id.uuidString, forKey: selectedKey)
        objectWillChange.send()
    }

    // MARK: - CRUD

    func addServer(_ server: ServerEntry) {
        var entry = server
        // Sanitize URL before saving
        entry.url = entry.sanitizedURL
        customServers.append(entry)
        saveCustomServers()
    }

    func updateServer(_ server: ServerEntry) {
        guard let idx = customServers.firstIndex(where: { $0.id == server.id }) else { return }
        var entry = server
        entry.url = entry.sanitizedURL
        customServers[idx] = entry
        saveCustomServers()
    }

    func deleteServer(_ server: ServerEntry) {
        guard !server.isDefault else { return }
        let wasSelected = selectedServer.id == server.id
        customServers.removeAll { $0.id == server.id }
        if wasSelected {
            selectServer(defaultServer)
        }
        saveCustomServers()
    }

    // MARK: - Persistence

    private func loadCustomServers() {
        guard let data = UserDefaults.standard.data(forKey: serversKey) else { return }
        customServers = (try? JSONDecoder().decode([ServerEntry].self, from: data)) ?? []
    }

    private func saveCustomServers() {
        let data = try? JSONEncoder().encode(customServers)
        UserDefaults.standard.set(data, forKey: serversKey)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/VMflow/Services/ServerStore.swift
git commit -m "feat(ios): add ServerStore for managing saved server configurations"
```

### Task 3: Refactor SupabaseService to support reconfigure()

**Files:**
- Modify: `ios/VMflow/Services/SupabaseService.swift:31-42`

- [ ] **Step 1: Update SupabaseService**

Replace `SupabaseService` class (lines 31-42) with:

```swift
/// Singleton providing the configured Supabase client instance.
/// All services and view models access Supabase through this shared client.
/// @MainActor ensures reconfigure() is only called from the main thread.
@MainActor
final class SupabaseService {
    static let shared = SupabaseService()

    private(set) var client: SupabaseClient
    private(set) var supabaseURL: URL

    private init() {
        let server = ServerStore.shared.selectedServer
        let url = URL(string: server.sanitizedURL) ?? AppConfig.supabaseURL
        supabaseURL = url
        client = SupabaseClient(supabaseURL: url, supabaseKey: server.anonKey)
    }

    /// Recreate the Supabase client with new server credentials.
    /// Must only be called from the login screen when no active sessions exist.
    func reconfigure(url: URL, anonKey: String) {
        supabaseURL = url
        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }
}
```

- [ ] **Step 2: Verify the app builds**

Run: `xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/Services/SupabaseService.swift
git commit -m "feat(ios): make SupabaseService reconfigurable for server switching"
```

### Task 4: Fix stale client references in AuthService

**Files:**
- Modify: `ios/VMflow/Services/AuthService.swift:15` (let → computed property)
- Modify: `ios/VMflow/Services/AuthService.swift:18-38` (extract listener into restartable method)
- Modify: `ios/VMflow/Services/AuthService.swift:119` (AppConfig → SupabaseService URL)

- [ ] **Step 1: Change `private let client` to computed property**

In `ios/VMflow/Services/AuthService.swift`, replace line 15:

```swift
    private let client = SupabaseService.shared.client
```

with:

```swift
    private var client: SupabaseClient { SupabaseService.shared.client }
```

- [ ] **Step 2: Extract auth listener into restartable method**

Replace the `init()` body (lines 18-39) with:

```swift
    init() {
        startAuthListener()
    }

    /// (Re)start the auth state change listener on the current Supabase client.
    /// Called on init and after server reconfiguration.
    func restartAuthListener() {
        authStateTask?.cancel()
        startAuthListener()
    }

    private func startAuthListener() {
        authStateTask = Task { [weak self] in
            guard let self else { return }
            await self.checkSession()
            for await (event, _) in self.client.auth.authStateChanges {
                switch event {
                case .signedIn:
                    self.isAuthenticated = true
                    await self.fetchOrganization()
                case .signedOut:
                    self.isAuthenticated = false
                    self.organization = nil
                    self.role = nil
                default:
                    break
                }
                self.isLoading = false
            }
        }
    }
```

- [ ] **Step 3: Fix the debug print in fetchOrganization**

In `fetchOrganization()` (line 119), replace:

```swift
            print("[AuthService] Fetching organization from \(AppConfig.supabaseURL)/functions/v1/get-my-organization")
```

with:

```swift
            print("[AuthService] Fetching organization from \(SupabaseService.shared.supabaseURL)/functions/v1/get-my-organization")
```

- [ ] **Step 4: Verify build**

Run: `xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add ios/VMflow/Services/AuthService.swift
git commit -m "feat(ios): make AuthService client dynamic with restartable auth listener"
```

### Task 5: Fix stale client references in RealtimeService and NotificationService

**Files:**
- Modify: `ios/VMflow/Services/RealtimeService.swift:18`
- Modify: `ios/VMflow/Services/NotificationService.swift:63`

- [ ] **Step 1: Fix RealtimeService**

In `ios/VMflow/Services/RealtimeService.swift`, replace line 18:

```swift
    private let client = SupabaseService.shared.client
```

with:

```swift
    private var client: SupabaseClient { SupabaseService.shared.client }
```

- [ ] **Step 2: Fix NotificationService**

In `ios/VMflow/Services/NotificationService.swift`, replace line 63:

```swift
    private let client = SupabaseService.shared.client
```

with:

```swift
    private var client: SupabaseClient { SupabaseService.shared.client }
```

- [ ] **Step 3: Verify build**

Run: `xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ios/VMflow/Services/RealtimeService.swift ios/VMflow/Services/NotificationService.swift
git commit -m "feat(ios): use dynamic client references in RealtimeService and NotificationService"
```

### Task 6: Fix ProductImage to use dynamic server URL

**Files:**
- Modify: `ios/VMflow/Views/Components/ProductImage.swift:11`

- [ ] **Step 1: Replace AppConfig reference**

In `ios/VMflow/Views/Components/ProductImage.swift`, replace line 11:

```swift
        let baseURL = AppConfig.supabaseURL.absoluteString
```

with:

```swift
        let baseURL = SupabaseService.shared.supabaseURL.absoluteString
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/Views/Components/ProductImage.swift
git commit -m "fix(ios): use dynamic server URL for product images instead of build-time AppConfig"
```

---

## Chunk 2: iOS UI — Server Selection Sheet + Login Integration

### Task 7: Create ServerSelectionSheet

**Files:**
- Create: `ios/VMflow/Views/Auth/ServerSelectionSheet.swift`
- Reference: `ios/VMflow/Services/ServerStore.swift` (allServers, selectServer, deleteServer)
- Reference: `ios/VMflow/Services/SupabaseService.swift` (reconfigure)
- Reference: `ios/VMflow/Services/AuthService.swift` (restartAuthListener)

- [ ] **Step 1: Create the server selection bottom sheet**

```swift
import SwiftUI

/// Bottom sheet showing all configured servers with selection, delete, and add actions.
struct ServerSelectionSheet: View {
    @EnvironmentObject var auth: AuthService
    @ObservedObject var serverStore = ServerStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showAddServer = false
    @State private var editingServer: ServerEntry?

    var body: some View {
        NavigationStack {
            List {
                // Server list
                Section {
                    ForEach(serverStore.allServers) { server in
                        serverRow(server)
                    }
                    .onDelete { indexSet in
                        // Offset by 1 because default server is at index 0
                        for index in indexSet {
                            let server = serverStore.allServers[index]
                            if !server.isDefault {
                                serverStore.deleteServer(server)
                            }
                        }
                    }
                }

                // Add button
                Section {
                    Button {
                        showAddServer = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.dashed")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                            VStack(alignment: .leading) {
                                Text("Add Self-hosted", comment: "Button to add a self-hosted server configuration")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(Text("Select Server", comment: "Title of the server selection sheet"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done", comment: "Dismiss button")) {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showAddServer) {
                AddServerView()
            }
            .sheet(item: $editingServer) { server in
                AddServerView(editing: server)
            }
        }
    }

    @ViewBuilder
    private func serverRow(_ server: ServerEntry) -> some View {
        let isSelected = server.id == serverStore.selectedServer.id

        Button {
            selectServer(server)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: server.isDefault ? "cloud.fill" : "server.rack")
                    .font(.title3)
                    .foregroundStyle(server.isDefault ? .blue : .secondary)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(server.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                        .fontWeight(.semibold)
                }
            }
        }
        .deleteDisabled(server.isDefault)
        .swipeActions(edge: .trailing) {
            if !server.isDefault {
                Button(role: .destructive) {
                    serverStore.deleteServer(server)
                } label: {
                    Label(String(localized: "Delete", comment: "Delete server action"), systemImage: "trash")
                }
                Button {
                    editingServer = server
                } label: {
                    Label(String(localized: "Edit", comment: "Edit server action"), systemImage: "pencil")
                }
                .tint(.orange)
            }
        }
    }

    private func selectServer(_ server: ServerEntry) {
        guard server.id != serverStore.selectedServer.id else {
            dismiss()
            return
        }
        serverStore.selectServer(server)
        let url = URL(string: server.sanitizedURL)!
        SupabaseService.shared.reconfigure(url: url, anonKey: server.anonKey)
        auth.restartAuthListener()
        dismiss()
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/VMflow/Views/Auth/ServerSelectionSheet.swift
git commit -m "feat(ios): add ServerSelectionSheet for server selection bottom sheet"
```

### Task 8: Create AddServerView with QR scanning

**Files:**
- Create: `ios/VMflow/Views/Auth/AddServerView.swift`
- Create: `ios/VMflow/Views/Auth/QRScannerView.swift`

- [ ] **Step 1: Create QRScannerView using AVFoundation**

```swift
import SwiftUI
import AVFoundation

/// Camera-based QR code scanner using AVFoundation.
struct QRScannerView: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onCodeScanned = { code in
            onCodeScanned(code)
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }
        if session.canAddInput(input) { session.addInput(input) }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.layer.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }
        hasScanned = true
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        onCodeScanned?(value)
    }
}
```

- [ ] **Step 2: Create AddServerView**

```swift
import SwiftUI

/// Fullscreen form for adding or editing a self-hosted server configuration.
/// QR code scanning is the primary input method; manual entry is secondary.
struct AddServerView: View {
    @ObservedObject var serverStore = ServerStore.shared
    @Environment(\.dismiss) private var dismiss

    /// If set, we are editing an existing server rather than adding a new one.
    var editing: ServerEntry?

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var anonKey: String = ""
    @State private var showScanner = false
    @State private var scanError: String?

    private var isEditing: Bool { editing != nil }

    private var isFormValid: Bool {
        let entry = ServerEntry(id: UUID(), name: name, url: url, anonKey: anonKey, isDefault: false)
        return entry.isValid
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // QR Scanner Button
                    Button {
                        showScanner = true
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 48))
                                .foregroundStyle(.blue)
                            Text("Scan QR Code", comment: "QR scan button title")
                                .font(.headline)
                            Text("Scan the code from your web dashboard", comment: "QR scan button subtitle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .background(.fill.tertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)

                    // Divider
                    HStack {
                        Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1)
                        Text("or enter manually", comment: "Divider between QR scan and manual entry")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1)
                    }

                    // Manual entry fields
                    VStack(spacing: 16) {
                        formField(
                            label: "Name",
                            placeholder: String(localized: "My Server", comment: "Server name placeholder"),
                            text: $name
                        )
                        formField(
                            label: "Supabase URL",
                            placeholder: "https://supabase.example.com",
                            text: $url,
                            keyboardType: .URL,
                            autocapitalization: .never
                        )
                        formField(
                            label: "Anon Key",
                            placeholder: "eyJhbGciOi...",
                            text: $anonKey,
                            autocapitalization: .never
                        )
                    }

                    if let error = scanError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(24)
            }
            .navigationTitle(Text(isEditing
                ? String(localized: "Edit Server", comment: "Navigation title when editing")
                : String(localized: "New Server", comment: "Navigation title when adding")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", comment: "Cancel button")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Save button")) {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isFormValid)
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    handleQRCode(code)
                    showScanner = false
                }
                .ignoresSafeArea()
            }
            .onAppear {
                if let server = editing {
                    name = server.name
                    url = server.url
                    anonKey = server.anonKey
                }
            }
        }
    }

    @ViewBuilder
    private func formField(
        label: String,
        placeholder: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType = .default,
        autocapitalization: TextInputAutocapitalization = .sentences
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            TextField(placeholder, text: text)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled()
                .padding(12)
                .background(.fill.tertiary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func handleQRCode(_ code: String) {
        scanError = nil
        guard let data = code.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["v"] as? Int, version == 1,
              let scannedURL = json["url"] as? String,
              let scannedKey = json["anonKey"] as? String else {
            scanError = String(localized: "Invalid QR Code", comment: "Error when QR code is not a valid server config")
            return
        }
        url = scannedURL
        anonKey = scannedKey
        // Name left empty for user to fill in
    }

    private func save() {
        if let existing = editing {
            var updated = existing
            updated.name = name
            updated.url = url
            updated.anonKey = anonKey
            serverStore.updateServer(updated)
        } else {
            let entry = ServerEntry(
                id: UUID(),
                name: name,
                url: url,
                anonKey: anonKey,
                isDefault: false
            )
            serverStore.addServer(entry)
        }
        dismiss()
    }
}
```

- [ ] **Step 3: Verify build**

Run: `xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ios/VMflow/Views/Auth/QRScannerView.swift ios/VMflow/Views/Auth/AddServerView.swift
git commit -m "feat(ios): add AddServerView with QR scanning and manual server entry"
```

### Task 9: Integrate server selector into LoginView

**Files:**
- Modify: `ios/VMflow/Views/Auth/LoginView.swift:4` (add serverStore), `ios/VMflow/Views/Auth/LoginView.swift:108-109` (add server indicator)

- [ ] **Step 1: Add state and server indicator to LoginView**

Add after line 9 (`@FocusState private var focusedField: Field?`):

```swift
    @ObservedObject var serverStore = ServerStore.shared
    @State private var showServerSheet = false
```

Add after the `NavigationLink { RegisterView() }` block (after line 108, before the closing `}`), before `.padding(.bottom, 40)`:

```swift
                // Server indicator
                Button {
                    showServerSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Connected to", comment: "Server indicator prefix on login screen")
                            .foregroundStyle(.secondary)
                        Text(serverStore.selectedServer.name)
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                }
                .sheet(isPresented: $showServerSheet) {
                    ServerSelectionSheet()
                }
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/Views/Auth/LoginView.swift
git commit -m "feat(ios): add server indicator and selection sheet to login screen"
```

### Task 10: Add server indicator to RegisterView

**Files:**
- Modify: `ios/VMflow/Views/Auth/RegisterView.swift`

- [ ] **Step 1: Add server indicator below the Create Account button**

Add after line 5 (`@Environment(\.dismiss) private var dismiss`):

```swift
    @ObservedObject var serverStore = ServerStore.shared
```

Add after the register button block (after line 132, `.padding(.horizontal, 24)`), before `.padding(.bottom, 40)`:

```swift
                // Server indicator
                HStack(spacing: 4) {
                    Text("Connected to", comment: "Server indicator prefix on register screen")
                        .foregroundStyle(.secondary)
                    Text(serverStore.selectedServer.name)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
```

Note: The register screen shows the indicator as read-only (no tap action) since the server should be selected on the login screen before navigating to register.

- [ ] **Step 2: Verify build**

Run: `xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/Views/Auth/RegisterView.swift
git commit -m "feat(ios): show connected server indicator on register screen"
```

---

## Chunk 3: Management Frontend — Mobile App QR Code Page

### Task 11: Verify qrcode library is available

**Note:** The `qrcode` package is already installed (`management-frontend/package.json` line 30, used in `app/pages/devices/index.vue`). No installation needed. Skip to Task 12.

### Task 12: Add i18n keys for mobile app page

**Files:**
- Modify: `management-frontend/i18n/locales/en.json`
- Modify: `management-frontend/i18n/locales/de.json`

- [ ] **Step 1: Add English i18n keys**

In `management-frontend/i18n/locales/en.json`, add to the `"nav"` object (after `"cashBook": "Cash Book"`):

```json
    "mobileApp": "Mobile App"
```

Add a new top-level `"mobileApp"` section:

```json
  "mobileApp": {
    "title": "Mobile App Setup",
    "description": "Connect the VMflow iOS app to this server.",
    "step1": "Download the VMflow app",
    "step2": "Tap \"Add Self-hosted\" on the login screen",
    "step3": "Scan this QR code",
    "orManual": "Or enter manually",
    "supabaseUrl": "Supabase URL",
    "anonKey": "Anon Key",
    "copied": "Copied!"
  }
```

- [ ] **Step 2: Add German i18n keys**

In `management-frontend/i18n/locales/de.json`, add to the `"nav"` object:

```json
    "mobileApp": "Mobile App"
```

Add a new top-level `"mobileApp"` section:

```json
  "mobileApp": {
    "title": "Mobile App Einrichtung",
    "description": "Verbinde die VMflow iOS App mit diesem Server.",
    "step1": "Lade die VMflow App herunter",
    "step2": "Tippe auf „Self-hosted hinzufügen" auf dem Login-Screen",
    "step3": "Scanne diesen QR-Code",
    "orManual": "Oder manuell eingeben",
    "supabaseUrl": "Supabase URL",
    "anonKey": "Anon Key",
    "copied": "Kopiert!"
  }
```

- [ ] **Step 3: Commit**

```bash
git add management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
git commit -m "feat(frontend): add i18n keys for mobile app setup page (en/de)"
```

### Task 13: Add Mobile App nav item to sidebar

**Files:**
- Modify: `management-frontend/app/components/AppSidebar.vue:1` (import), `management-frontend/app/components/AppSidebar.vue:118-124` (navSecondary)

- [ ] **Step 1: Add icon import**

In `management-frontend/app/components/AppSidebar.vue`, add `IconDeviceMobile` to the tabler icons import (line 3-16):

```typescript
  IconDeviceMobile,
```

- [ ] **Step 2: Add nav item to navSecondary**

Replace the `navSecondary` computed (lines 118-124) with:

```typescript
const navSecondary = computed(() => [
  {
    title: t('nav.mobileApp'),
    url: "/mobile-app",
    icon: IconDeviceMobile,
  },
  {
    title: t('nav.getHelp'),
    url: "#",
    icon: IconHelp,
  },
])
```

- [ ] **Step 3: Fix NavSecondary to use NuxtLink instead of `<a>` for internal routes**

In `management-frontend/app/components/NavSecondary.vue`, replace the `<a>` tag (line 41) with conditional NuxtLink:

```vue
            <NuxtLink v-if="!item.url.startsWith('#')" :to="item.url" @click="handleNavClick">
              <component :is="item.icon" v-if="item.icon" />
              {{ item.title }}
            </NuxtLink>
            <a v-else :href="item.url" @click="handleNavClick">
              <component :is="item.icon" v-if="item.icon" />
              {{ item.title }}
            </a>
```

- [ ] **Step 4: Commit**

```bash
git add management-frontend/app/components/AppSidebar.vue management-frontend/app/components/NavSecondary.vue
git commit -m "feat(frontend): add Mobile App navigation item to sidebar"
```

### Task 14: Create /mobile-app page

**Files:**
- Create: `management-frontend/app/pages/mobile-app/index.vue`

- [ ] **Step 1: Create the mobile app setup page**

```vue
<script setup lang="ts">
import QRCode from 'qrcode'

const { t } = useI18n()
const config = useRuntimeConfig()

// Get the Supabase URL and anon key for the QR code
const supabaseUrl = config.public.supabase.url as string
const supabaseKey = config.public.supabase.key as string

const qrPayload = JSON.stringify({
  v: 1,
  url: supabaseUrl,
  anonKey: supabaseKey,
})

const qrDataUrl = ref('')
const copiedField = ref<string | null>(null)

onMounted(async () => {
  qrDataUrl.value = await QRCode.toDataURL(qrPayload, {
    width: 280,
    margin: 2,
    color: { dark: '#000000', light: '#ffffff' },
  })
})

async function copyToClipboard(text: string, field: string) {
  await navigator.clipboard.writeText(text)
  copiedField.value = field
  setTimeout(() => { copiedField.value = null }, 2000)
}
</script>

<template>
  <div class="mx-auto max-w-lg space-y-8 py-8 px-4">
    <div>
      <h1 class="text-2xl font-bold tracking-tight">{{ t('mobileApp.title') }}</h1>
      <p class="mt-1 text-muted-foreground">{{ t('mobileApp.description') }}</p>
    </div>

    <!-- Steps -->
    <ol class="list-inside list-decimal space-y-3 text-sm">
      <li>{{ t('mobileApp.step1') }}</li>
      <li>{{ t('mobileApp.step2') }}</li>
      <li>{{ t('mobileApp.step3') }}</li>
    </ol>

    <!-- QR Code -->
    <div class="flex justify-center rounded-lg border bg-white p-6">
      <img v-if="qrDataUrl" :src="qrDataUrl" alt="Server QR Code" class="h-[280px] w-[280px]" />
      <div v-else class="flex h-[280px] w-[280px] items-center justify-center">
        <div class="text-muted-foreground">Loading...</div>
      </div>
    </div>

    <!-- Manual entry -->
    <div class="space-y-4">
      <p class="text-center text-sm text-muted-foreground">{{ t('mobileApp.orManual') }}</p>

      <div class="space-y-3">
        <div>
          <label class="text-xs font-medium text-muted-foreground uppercase">{{ t('mobileApp.supabaseUrl') }}</label>
          <div
            class="mt-1 flex cursor-pointer items-center justify-between rounded-md border bg-muted/50 px-3 py-2 text-sm font-mono"
            @click="copyToClipboard(supabaseUrl, 'url')"
          >
            <span class="truncate">{{ supabaseUrl }}</span>
            <span v-if="copiedField === 'url'" class="ml-2 text-xs text-green-600 shrink-0">{{ t('mobileApp.copied') }}</span>
          </div>
        </div>

        <div>
          <label class="text-xs font-medium text-muted-foreground uppercase">{{ t('mobileApp.anonKey') }}</label>
          <div
            class="mt-1 flex cursor-pointer items-center justify-between rounded-md border bg-muted/50 px-3 py-2 text-sm font-mono"
            @click="copyToClipboard(supabaseKey, 'key')"
          >
            <span class="truncate">{{ supabaseKey }}</span>
            <span v-if="copiedField === 'key'" class="ml-2 text-xs text-green-600 shrink-0">{{ t('mobileApp.copied') }}</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
```

- [ ] **Step 2: Verify dev server runs**

Run: `cd management-frontend && npm run dev -- --port 3001 &` then open `http://localhost:3001/mobile-app` and verify the page loads with QR code.

- [ ] **Step 3: Commit**

```bash
git add management-frontend/app/pages/mobile-app/index.vue
git commit -m "feat(frontend): add /mobile-app page with QR code for iOS app onboarding"
```

---

## Chunk 4: Final Build Verification

### Task 15: Full iOS build verification

- [ ] **Step 1: Full build**

Run: `xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Check for remaining AppConfig.supabaseURL references outside SupabaseService**

Run a grep to ensure no other files reference `AppConfig.supabaseURL` directly (except `SupabaseService.swift` which uses it for the default server):

```bash
grep -rn "AppConfig.supabaseURL" ios/VMflow/ --include="*.swift" | grep -v "SupabaseService.swift"
```

Expected: No matches (all references should now go through `SupabaseService.shared.supabaseURL`)

- [ ] **Step 3: Check for remaining `private let client = SupabaseService` in singleton services**

```bash
grep -rn "private let client = SupabaseService" ios/VMflow/Services/
```

Expected: No matches (AuthService, RealtimeService, NotificationService all changed to computed property). ViewModels still use `let` which is correct.
