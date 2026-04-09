---
phase: 15-mobile-payment
topic: Stripe Payment Integration for Vending Machines
depth: standard
confidence: HIGH
created: 2026-04-09
---

# Discovery: Stripe Payment Integration

**Recommendation:** Use Stripe Payment Intents + Payment Element with hybrid confirmation (client-side + webhook backup). Per-company Stripe keys following existing `anthropic_api_key` pattern. Credit delivery via existing MQTT publish helper.

**Confidence:** HIGH — Stripe is well-documented, Deno compatibility verified, existing codebase patterns clear.

## Objective

What we needed to learn before planning:
1. How does Stripe Payment Intents work with Deno edge functions?
2. How to store per-company Stripe API keys securely?
3. How to deliver credit to ESP32 after successful payment?
4. Webhooks vs client-side confirmation — which approach?
5. What DB tables are needed for payment records?

## Findings

### 1. Stripe + Deno Compatibility

**Import:** `import Stripe from "npm:stripe@^13.0.0"` — works natively in Deno 1.28+.
**Do NOT use** esm.sh for Stripe — npm specifier is more reliable.

**PaymentIntent creation:**
```typescript
const stripe = new Stripe(secretKey, { apiVersion: '2024-11-20.acacia' })
const pi = await stripe.paymentIntents.create({
  amount: 250,       // cents
  currency: 'eur',
  metadata: { machine_id, product_name, subdomain },
})
return { clientSecret: pi.client_secret }
```

### 2. Payment Element (Client-Side)

Stripe Payment Element automatically includes Apple Pay, Google Pay, cards based on device/location.

**Requirements:**
- Load `https://js.stripe.com/v3/` (always from Stripe CDN)
- Initialize with `clientSecret` from PaymentIntent
- Apple Pay: requires domain registration in Stripe Dashboard
- Google Pay: requires HTTPS with valid TLS certificate

**No extra code for Apple Pay/Google Pay** — Payment Element handles it.

### 3. Per-Company Keys — Existing Pattern

`companies.anthropic_api_key` is the existing pattern:
- Column added to `companies` table as `TEXT`
- Admin-only UPDATE policy via `i_am_admin()`
- Stored in plaintext (standard for Supabase, same as Stripe best practice for server-side keys)

**For Stripe, need 2 keys per company:**
- `stripe_secret_key` — server-side (never exposed to client)
- `stripe_publishable_key` — client-side (safe to expose, needed for Stripe.js init)

### 4. Credit Delivery — Existing send-credit Flow

`send-credit/index.ts` flow:
1. Auth check → get company_id
2. Fetch device from `embeddeds` by device_id + company → get passkey
3. Build 19-byte XOR-encrypted payload (cmd=0x20, amount, timestamp, checksum)
4. Publish to MQTT topic `/{company_id}/{device_id}/credit` via `mqtt-publish.ts`

**For Stripe webhook handler:** Can call `mqttPublish()` directly (shared module) rather than HTTP-calling send-credit. Same encryption logic inline.

### 5. Webhooks vs Client-Side — HYBRID

**Decision: Hybrid approach**

| Step | Mechanism | Purpose |
|------|-----------|---------|
| Primary | Client-side `confirm-payment` call | Immediate credit delivery (happy path) |
| Backup | Stripe webhook `payment_intent.succeeded` | Catches missed deliveries (browser closed, 3DS redirect) |

Both are idempotent — use PaymentIntent ID as dedup key in `payments` table.

**Webhook URL pattern for multi-tenant:**
`/functions/v1/stripe-webhook?company_id={uuid}`
- Company configures this in their Stripe Dashboard
- Handler reads company_id from query → looks up `stripe_webhook_secret` → verifies signature

## Comparison

| Criteria | Client-only | Webhook-only | Hybrid |
|----------|------------|-------------|--------|
| Reliability | Medium (browser can close) | High (72h retry) | High |
| Latency | Instant | 1-5s delay | Instant (primary) |
| Complexity | Low | Medium | Medium |
| Multi-tenant | Simple | Need per-company webhook secrets | Need both |

## Recommendation

**Choose: Hybrid (client-side + webhook)**

**Rationale:** Customer is physically at the machine — instant feedback is important. Webhook ensures no lost payments. Both paths are idempotent via payments table.

**Caveats:**
- Each company must configure webhook URL in their Stripe Dashboard (manual step, documented in settings page)
- Domain registration needed for Apple Pay (manual step per domain)
- `stripe_webhook_secret` is a third key companies need to configure

## Architecture

```
Customer Phone                    Server                         ESP32
     |                              |                              |
     |-- Select product ----------->|                              |
     |<- clientSecret --------------|  create-payment-intent       |
     |                              |  (uses company stripe key)   |
     |-- Pay (Stripe Element) ----->|                              |
     |-- confirm-payment ---------->|  confirm-payment             |
     |                              |  verify PI succeeded         |
     |                              |  record in payments table    |
     |                              |-- MQTT credit -------------->|
     |<- success --------------------|                             |
     |                              |                              |
     |  [BACKUP: Stripe webhook]--->|  stripe-webhook              |
     |                              |  (idempotent, same logic)    |
```

## Open Questions

None — discovery answered all questions.

## Quality Report

**Sources consulted:**
- Stripe Payment Intents API docs (2026)
- Stripe Payment Element integration guide (2026)
- Stripe Webhook best practices (2026)
- Stripe + Deno compatibility (DEV Community, 2025)
- Existing codebase: send-credit/index.ts, mqtt-publish.ts, companies migrations

**Verification:**
- Deno npm: specifier for Stripe: Verified via Deno docs + community examples
- Payment Element auto-includes Apple/Google Pay: Verified via Stripe docs
- Webhook retry behavior (72h, 16 attempts): Verified via Stripe docs
- anthropic_api_key column pattern: Verified in migration 20260319000000

---
*Discovery completed: 2026-04-09*
*Confidence: HIGH*
*Ready for: /paul:plan Phase 15*
