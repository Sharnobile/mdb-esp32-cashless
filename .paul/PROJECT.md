# Project: mdb-esp32-cashless

## What This Is

An open-source MDB telemetry system for vending machines using ESP32-S3 firmware, a self-hosted Docker backend (Supabase + MQTT), and a Nuxt 4 management dashboard. Enables vending machine operators to accept cashless payments, monitor device health, track sales, and manage inventory remotely.

## Core Value

Vending machine operators can manage all the telemetry, monitor sales, and optimize inventory from a single dashboard.

## Current State

| Attribute | Value |
|-----------|-------|
| Version | v1.2 |
| Status | Production |
| Last Updated | 2026-03-19 |

## Requirements

### Validated (Shipped)

- [x] MDB cashless payment via ESP32-S3 firmware
- [x] Self-hosted backend (Supabase + MQTT + Deno forwarder)
- [x] Management dashboard (machines, sales, products, inventory)
- [x] Device provisioning (SoftAP + captive portal + claim flow)
- [x] OTA firmware updates
- [x] Warehouse inventory management with FIFO tracking
- [x] Machine tray/slot configuration with auto stock decrement
- [x] Multi-tenancy with RLS
- [x] Push notifications
- [x] MDB diagnostics logging

### Active (In Progress)

- [x] AI-powered sales/inventory analysis and recommendations
  - [x] Phase 01: KPI aggregation RPC (`get_machine_insights_kpis`) — Phase 01 complete
  - [x] Phase 02: `machine-insights` edge function + per-company Anthropic API key — Phase 02 complete
  - [x] Phase 03: Dashboard UI — "AI Insights" button + recommendations Sheet — Phase 03 complete
- [x] Warehouse picking optimization (sorted pick lists for refill tours)
  - [x] Phase 04: Warehouse product positions — table + admin UI — Phase 04 complete
  - [x] Phase 05: Sorted pick list — refill wizard integration + per-machine/combined mode — Phase 05 complete
- [x] Refill tour optimizations
  - [x] Phase 06: Custom packing quantities — adjustable amounts per product per machine — Phase 06 complete
  - [x] Phase 07: Tour history — dedicated page showing past refill tours with detail — Phase 07 complete

### Planned (Next)

- [ ] SonarQube code quality integration (configured via /paul:flows)

### Out of Scope

- Real-time AI recommendations (on-demand only, not streaming)
- Cross-company benchmarking (single-tenant analysis only)

## Target Users

**Primary:** Vending machine operators
- Manage fleets of vending machines
- Need real-time sales and inventory visibility
- Want to optimize product placement and refill schedules

**Secondary:** Vending machine technicians
- Monitor device health and MDB diagnostics
- Perform firmware updates and troubleshooting

## Context

**Business Context:**
Production system with live ESP32 devices installed in the field. Backward compatibility is critical — not all devices run latest firmware.

**Technical Context:**
- Firmware: ESP-IDF v5.x, FreeRTOS, MDB protocol (9600 baud, 9-bit)
- Backend: Supabase (PostgreSQL + Auth + Edge Functions), Mosquitto MQTT, Deno forwarder
- Frontend: Nuxt 4, shadcn-nuxt, TailwindCSS 4
- Security: XOR obfuscation on MQTT payloads with timestamp replay prevention

## Constraints

### Technical Constraints
- All changes must be backward-compatible with deployed ESP32 firmware
- MQTT payloads must use XOR encryption (except diagnostics)
- ESP-IDF v5.x with CMake build system
- Self-hosted Docker deployment

### Business Constraints
- Production system is live — no breaking changes
- Multi-tenant architecture required

## Key Decisions

| Decision | Rationale | Date | Status |
|----------|-----------|------|--------|
| XOR encryption for MQTT | Lightweight security suitable for ESP32 | - | Active |
| Supabase for backend | Auth + DB + Edge Functions + Storage in one stack | - | Active |
| Nuxt 4 for dashboard | SSR + Vue 3 + TypeScript ecosystem | - | Active |
| AI KPIs pre-aggregated in SQL (not app layer) | Keeps edge function simple, reduces Claude API token usage, enforces tenancy at DB level | 2026-03-18 | Active |
| `security definer` + manual `p_company_id` check for AI RPCs | Service role client in edge functions bypasses RLS — manual check is the tenancy gate | 2026-03-18 | Active |
| Schema FK pattern: `company`, not `company_id` | Existing schema uses `company` as the FK column name in vendingMachine, embeddeds, products | 2026-03-18 | Active |
| Denormalized `company_id` on warehouse position tables | Matches `warehouse_stock_batches` RLS pattern — simpler policies | 2026-03-18 | Active |
| Per-company Anthropic API key (not global env var) | Multi-tenant friendly — each company manages their own key in settings | 2026-03-19 | Active |
| `claude-haiku-4-5` for AI insights | Fast, cheap, well-suited for structured JSON output tasks | 2026-03-19 | Active |

## Success Metrics

| Metric | Target | Current | Status |
|--------|--------|---------|--------|
| Device uptime | >99% | - | - |
| Dashboard usability | Operators self-serve | - | On track |

## Tech Stack

| Layer | Technology | Notes |
|-------|------------|-------|
| Firmware | ESP-IDF v5.x | C, FreeRTOS, NimBLE |
| Backend | Supabase (PostgreSQL) | Docker self-hosted |
| Edge Functions | Deno | Supabase Edge Runtime |
| Frontend | Nuxt 4 | Vue 3, TypeScript |
| UI | shadcn-nuxt + TailwindCSS 4 | |
| MQTT | Eclipse Mosquitto | Deno forwarder bridge |
| Auth | Supabase GoTrue | JWT + RLS |

---
*PROJECT.md — Updated when requirements or context change*
*Last updated: 2026-03-19 after Phase 03 (insights-ui) — Milestone v1.1 complete*
