# Configurable Server Selection

**Date:** 2026-04-09
**Scope:** iOS App + Management Frontend

## Problem

The iOS app currently has the Supabase URL hardcoded via xcconfig/Info.plist at build time. For the app to be usable by anyone running a self-hosted VMflow backend, the server must be selectable at runtime.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Server selector placement | Subtle link below login form | Clean for 90% of users on default server; power users find it easily |
| Server list UI | Bottom sheet from login screen | Native iOS feel, non-intrusive |
| Add server flow | Fullscreen with QR prominent | QR scanning is primary onboarding path; manual input secondary |
| Persistence | UserDefaults (JSON) | Anon key is public, no secrets to protect |
| SupabaseService change | `reconfigure()` on singleton | Minimal refactoring, all existing `SupabaseService.shared.client` calls unchanged |
| Pre-defined servers | VMflow Cloud only | Single production server, everything else is self-hosted |
| Server management | Editable + deletable | Self-hosted entries fully manageable; default server is read-only |

## Data Model

### ServerEntry

```swift
struct ServerEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String        // Display name, e.g. "VMflow Cloud"
    var url: String         // Supabase URL, e.g. "https://supabase.kerl-handel.de"
    var anonKey: String     // Supabase anon key
    let isDefault: Bool     // true = VMflow Cloud, not deletable/editable
}
```

Persisted in UserDefaults as JSON array under key `savedServers`. Active server tracked via `selectedServerId: UUID` in UserDefaults.

### QR Code Payload

```json
{
  "v": 1,
  "url": "https://supabase.example.com",
  "anonKey": "eyJhbGciOi..."
}
```

Encoded as a standard QR code containing this JSON string. The `v` field enables future format changes. The iOS app parses it, validates `v == 1` and JSON structure, then pre-fills URL + Anon Key fields; the user only adds a display name. Non-JSON or unrecognized QR content shows an error alert ("Ungültiger QR-Code").

## iOS App Changes

### New Files

#### `Services/ServerStore.swift`

Manages the server list. Responsibilities:
- Loads/saves `[ServerEntry]` from UserDefaults
- Always includes the hardcoded VMflow Cloud entry (from xcconfig values as fallback)
- CRUD for self-hosted entries (add, update, delete)
- `selectedServer: ServerEntry` computed property — returns the entry matching `selectedServerId`, falling back to the default
- `selectServer(_ entry: ServerEntry)` — updates `selectedServerId`

The default VMflow Cloud server uses the values from `AppConfig` (Info.plist/xcconfig), so Debug builds point to the local dev server and Release builds point to production. This preserves the existing dual-environment behavior.

#### `Views/Auth/ServerSelectionSheet.swift`

Bottom sheet presented from LoginView. Contents:
- List of all servers (default + saved) — each row shows icon, name, URL subtitle
- Active server has a checkmark
- Tap on a server → select it, dismiss sheet, reconfigure SupabaseService
- Swipe-to-delete on self-hosted entries
- Edit button (or context menu) on self-hosted entries → opens AddServerView in edit mode
- Dashed "Self-hosted hinzufügen" row at bottom → navigates to AddServerView

#### `Views/Auth/AddServerView.swift`

Fullscreen presented via NavigationView (or `.sheet`). Layout:
- Navigation bar: "Abbrechen" (left) / "Neuer Server" title / "Fertig" (right, disabled until valid)
- Large QR scan button area with explanation text ("Scanne den Code aus deinem Web-Dashboard")
- Divider "— oder manuell eingeben —"
- Text fields: Name, Supabase URL, Anon Key
- QR scan result auto-fills URL + Anon Key; user adds Name
- "Fertig" validates (non-empty fields, valid URL format) then saves via ServerStore
- Reused for editing: pre-fills fields, title changes to "Server bearbeiten"

Uses AVFoundation camera for QR scanning (similar to existing BarcodeScanner pattern in the frontend, but native iOS). Requires `NSCameraUsageDescription` in Info.plist (add if not already present).

URL validation must accept both HTTP and HTTPS schemes, and URLs with ports (e.g. `http://10.0.1.50:8000`). Trailing slashes should be stripped before saving.

### Modified Files

#### `Services/SupabaseService.swift`

Current state: singleton with `let client: SupabaseClient` initialized once from `AppConfig`.

Changes:
- `client` becomes `private(set) var` instead of `let`
- New computed property `supabaseURL: URL` for use by code that needs the active server URL (e.g. storage image URLs)
- New method `reconfigure(url: URL, anonKey: String)` that creates a new `SupabaseClient` instance
- `init()` reads from `ServerStore.shared.selectedServer` instead of hardcoded `AppConfig`
- `AppConfig` remains as fallback for the default server values

```swift
final class SupabaseService {
    static let shared = SupabaseService()
    private(set) var client: SupabaseClient
    private(set) var supabaseURL: URL

    private init() {
        let server = ServerStore.shared.selectedServer
        let url = URL(string: server.url)!
        supabaseURL = url
        client = SupabaseClient(supabaseURL: url, supabaseKey: server.anonKey)
    }

    func reconfigure(url: URL, anonKey: String) {
        supabaseURL = url
        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }
}
```

**Critical: stale client references.** Several services and all ViewModels capture `SupabaseService.shared.client` as `private let client` at init time. After `reconfigure()`, these hold a stale reference. The following services need changes:

| Service | Problem | Fix |
|---------|---------|-----|
| `AuthService` | Singleton, alive at app start. `let client` + `authStateChanges` async stream captured in `init()` | Computed property for `client` + `restartAuthListener()` method |
| `RealtimeService` | Static singleton, persists across login/logout cycles | Computed property for `client` |
| `NotificationService` | Static singleton, accessed early in `AppDelegate` | Computed property for `client` |

ViewModels (`DashboardViewModel`, `MachineListViewModel`, etc.) use `private let client` but are **not** singletons — they are created fresh when `MainTabView` appears (after login, after any server switch). They always capture the correct post-reconfigure client. No changes needed.

**Thread safety**: `SupabaseService.reconfigure()` must only be called from the main actor when no requests are in flight. Since it only runs from the login screen (no active sessions), this is guaranteed. Add `@MainActor` to `SupabaseService` to enforce this.

#### `Services/AuthService.swift`

Changes:
- `private let client = SupabaseService.shared.client` → `private var client: SupabaseClient { SupabaseService.shared.client }` (computed property, always reads current client for `signIn()`, `fetchOrganization()`, etc.)
- New method `restartAuthListener()`: cancels the existing `authStateTask`, then starts a new one that subscribes to `client.auth.authStateChanges` on the current (post-reconfigure) client. This is necessary because the `for await` loop in `init()` captures the async stream from the old client — after reconfigure, it would never receive events from the new client.
- `restartAuthListener()` is called by `ServerSelectionSheet` after `SupabaseService.reconfigure()` completes
- The debug print in `fetchOrganization()` that references `AppConfig.supabaseURL` should use `SupabaseService.shared.supabaseURL` instead

#### `Services/RealtimeService.swift`

Changes:
- `private let client = SupabaseService.shared.client` → `private var client: SupabaseClient { SupabaseService.shared.client }` (computed property)
- Since `RealtimeService` is a static singleton that persists across login/logout cycles, it must always read the current client. When `MainTabView` disappears (logout), realtime channels are stopped. On next login (possibly to a different server), `start()` creates new channels using the now-correct client.

#### `Services/NotificationService.swift`

Changes:
- `private let client = SupabaseService.shared.client` → `private var client: SupabaseClient { SupabaseService.shared.client }` (computed property)
- `NotificationService.shared` is accessed in `AppDelegate` at app launch for APNs token handling. With the computed property, it always uses the current client for backend registration calls.

#### `Views/Auth/LoginView.swift`

Changes:
- Add `@State private var showServerSheet = false`
- Below the "Registrieren" link, add tappable text: "Verbunden mit **{serverName}**"
- Tap sets `showServerSheet = true`
- `.sheet(isPresented: $showServerSheet)` presents `ServerSelectionSheet`
- Server name reads from `ServerStore.shared.selectedServer.name`

#### `Views/Auth/RegisterView.swift`

Changes:
- Same "Verbunden mit **{serverName}**" indicator as LoginView, so users know which server they are registering on

#### `Views/Components/ProductImage.swift`

Current state: uses `AppConfig.supabaseURL` directly to construct storage image URLs.

Changes:
- Replace `AppConfig.supabaseURL` with `SupabaseService.shared.supabaseURL`
- This ensures product images load from the correct server after a switch

#### `VMflowApp.swift`

No changes needed. `AuthService` is initialized here as `@StateObject` — since it now uses a computed property for the client, it always reads the current `SupabaseService.shared.client`. RootView already routes based on `auth.isAuthenticated`.

## Management Frontend Changes

### New Navigation Item

In the sidebar navigation (where "Get Help" lives), add a new item:
- Label: "Mobile App" (i18n: `nav.mobileApp`)
- Icon: smartphone icon from @tabler/icons-vue
- Position: above or below "Get Help" in the secondary nav section (`NavSecondary.vue`)

### New Page: `/mobile-app`

Simple page containing:
1. Brief setup instructions (3 steps):
   - "1. Lade die VMflow App herunter"
   - "2. Tippe auf 'Self-hosted hinzufügen' auf dem Login-Screen"
   - "3. Scanne diesen QR-Code"
2. QR code displaying the JSON payload `{"v": 1, "url": "<SUPABASE_URL>", "anonKey": "<ANON_KEY>"}`
3. Alternatively: "Oder gib diese Daten manuell ein:" with copyable URL + Anon Key fields

The QR code is generated client-side using a lightweight library (e.g., `qrcode` npm package or inline SVG generation). The Supabase URL comes from `useRuntimeConfig().public.supabase.url` and the anon key from `useRuntimeConfig().public.supabase.key` (injected by `@nuxtjs/supabase` module).

This page requires authentication (behind the auth middleware) since it's part of the organization context.

### i18n

New keys for both `en` and `de` locales covering the mobile app page content and navigation label.

## Server Switch Flow

Complete sequence when a user switches servers:

1. User taps "Verbunden mit VMflow Cloud" on login screen
2. Bottom sheet opens with server list
3. User taps a different server (or adds new one)
4. `ServerStore.selectServer()` updates `selectedServerId` in UserDefaults
5. `SupabaseService.shared.reconfigure()` creates new `SupabaseClient`
6. Login screen updates the "Verbunden mit..." label
7. User logs in with credentials for that server

If switching while already logged in (future consideration — currently only accessible from login screen): logout first, then reconfigure.

### i18n (iOS)

All new views use `String(localized:)` / `Localizable.xcstrings` with both `en` and `de` translations. Key strings:
- "Connected to" / "Verbunden mit"
- "Select Server" / "Server auswählen"
- "Add Self-hosted" / "Self-hosted hinzufügen"
- "New Server" / "Neuer Server"
- "Edit Server" / "Server bearbeiten"
- "Cancel" / "Abbrechen"
- "Done" / "Fertig"
- "Scan QR Code" / "QR-Code scannen"
- "or enter manually" / "oder manuell eingeben"
- "Invalid QR Code" / "Ungültiger QR-Code"
- "Name", "Supabase URL", "Anon Key" (same in both languages)

## What Does NOT Change

- All ViewModels continue using `SupabaseService.shared.client` via `private let client` — safe because they are non-singletons created fresh after login (after any server switch)
- Three singleton services (`AuthService`, `RealtimeService`, `NotificationService`) change `let client` to computed property — this is the only pattern change
- xcconfig files remain for build-time defaults (Debug = local dev, Release = production)
- No changes to the backend, edge functions, or MQTT
- No changes to the existing auth flow logic beyond the server-switch trigger and `restartAuthListener()`

## Edge Cases

- **Invalid server URL**: Show error on AddServerView validation. Optional: ping `/rest/v1/` to verify reachability before saving.
- **Server becomes unreachable**: Existing Supabase SDK error handling applies — login will fail with network error, user can switch back.
- **App update with new default server URL**: The default entry always reads from xcconfig/AppConfig, so it updates with the build.
- **Migration from old app version**: On first launch after update, `ServerStore` finds no saved servers → creates default entry from AppConfig, selects it. Existing session continues working since the SupabaseClient URL hasn't changed.
