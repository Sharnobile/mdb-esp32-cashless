# VMflow iOS App

Native iOS companion app for vending machine operators. Built with SwiftUI, targeting iOS 17+.

## Features

- **Dashboard** — KPI cards (revenue, sales, machine status, stock alerts), 30-day sales chart, recent sales feed
- **Machine Management** — Browse machines sorted by stock urgency, view per-machine details (overview, trays, sales history)
- **Tray Configuration** — Full CRUD for machine tray slots: add single/batch, edit, delete, quick stock adjustments
- **Refill Wizard** — Multi-step guided refill tour (pack, refill per machine, summary) optimized for one-handed field use

## Setup

### Prerequisites

- Xcode 15+ (iOS 17 SDK)
- A running VMflow backend (Supabase + MQTT via Docker)

### Steps

1. Open `VMflow/` in Xcode as a Swift Package (File > Open > select the `VMflow` folder containing `Package.swift`)
2. Alternatively, create a new Xcode project and add the Swift package dependency:
   - `https://github.com/supabase/supabase-swift` (from: 2.0.0)
3. Configure your Supabase credentials in `Resources/Info.plist`:
   - `SUPABASE_URL` — Your Supabase API URL (e.g., `http://10.0.1.181:8000` for local dev)
   - `SUPABASE_ANON_KEY` — Your Supabase anonymous key
4. Build and run on a simulator or device

### Environment Variables

| Key | Description | Example |
|-----|-------------|---------|
| `SUPABASE_URL` | Supabase API gateway URL | `http://10.0.1.181:8000` |
| `SUPABASE_ANON_KEY` | Supabase anonymous (public) key | `eyJ...` |

For local development, use the LAN IP of your Docker host (not `localhost`, which won't work from a physical device).

## Architecture

- **MVVM** pattern with SwiftUI + Combine
- **Swift Concurrency** (async/await) for all network calls
- **Supabase Swift SDK** for auth, database queries, and storage
- **Charts** framework for revenue visualization

### Structure

```
VMflow/
  VMflowApp.swift          — App entry point, auth routing
  Models/                  — Codable data models matching Supabase schema
  Services/
    SupabaseService.swift  — Singleton Supabase client
    AuthService.swift      — Auth state management
  ViewModels/
    DashboardViewModel     — Dashboard KPIs and chart data
    MachineListViewModel   — Machine list with stats
    MachineDetailViewModel — Single machine detail
    TrayViewModel          — Tray CRUD operations
    RefillWizardViewModel  — Multi-step refill flow
  Views/
    Auth/                  — Login, Register
    Dashboard/             — Dashboard, KPI cards
    Machines/              — Machine list, detail, cards
    Trays/                 — Tray list, edit sheet, rows
    Refill/                — Wizard container, packing, refill, summary
    Components/            — Reusable: StatusBadge, StockBar, ProductImage, KPICard
  Resources/
    Info.plist             — App config with Supabase credentials
```

## Data Flow

1. `AuthService` manages session state and organization membership
2. On successful login, the app fetches the user's organization via `get-my-organization` edge function
3. ViewModels query Supabase tables directly using the Swift SDK (`from().select().execute()`)
4. Product images load from Supabase Storage (`product-images` bucket) via `AsyncImage`
5. All prices are in EUR (not cents), matching the backend schema
