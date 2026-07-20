# Building Extensions for VMflow

VMflow has a lightweight **provider pattern** at a handful of "extension
points" — places where a feature inherently has multiple possible backends
(a data source, a search backend, an LLM, an import format, ...). Each
extension point exposes a stable interface; any number of providers can
implement it; every company independently chooses which providers are
active for them.

This is **not** a plugin framework, a marketplace, or a paid-extension
system. There's no sandboxing, no signing, no discovery service. It's a
contained adapter convention applied to specific features — see
`docs/superpowers/specs/2026-05-05-extension-provider-pattern-design.md`
for the full design rationale if you want the "why".

Two ways to extend VMflow, depending on what you're building:

- **Add a provider to an existing extension point** — e.g. a new deal-source
  retailer. Single-file change, goes through a normal PR. Start here — it's
  almost certainly what you want if you're integrating one more upstream
  service into a feature that already exists.
- **Add a brand-new extension point** — e.g. you want a feature that doesn't
  exist yet to be pluggable from day one. More involved: interface, table
  data, edge function, admin UI, docs. Only do this for a genuinely new
  provider pattern, not to route around an existing one.

Either way, you don't need to fork VMflow or run a separate plugin
repository: built-in providers live in this repo, and if you'd rather not
touch the codebase at all, every extension point also accepts a **webhook
provider** — an HTTPS endpoint you run yourself, in any language, on your
own infrastructure.

## Currently available extension points

| Extension point | Powers | Doc |
|---|---|---|
| `deal-source` | `/deals` retailer offer search | [`docs/extension-points/deal-source.md`](docs/extension-points/deal-source.md) |

More are planned (`image-search`, `ai-backend`, `import-format`,
`notification-channel`, `firmware-source` — see "Future Extension Points" in
the design spec) but none exist yet. If the feature you want to extend isn't
in the table above, it isn't pluggable yet — see "Adding a brand-new
extension point" below, or open an issue to discuss adding one.

## Adding a provider to an existing extension point

Using `deal-source` as the example (the only one that exists today, and the
template every future one follows):

1. Read the extension point's doc first — [`docs/extension-points/deal-source.md`](docs/extension-points/deal-source.md).
   It has the full interface, a worked reference implementation, and a
   copy-paste prompt for scaffolding the provider with Claude Code.
2. Create `Docker/supabase/functions/_shared/providers/deal-source/<your-id>.ts`
   exporting a `provider: DealSourceProvider` object. Copy the shape of
   [`marktguru.ts`](Docker/supabase/functions/_shared/providers/deal-source/marktguru.ts)
   in the same directory.
3. Create `<your-id>.test.ts` next to it — at minimum, unit tests for your
   pure normalization function (upstream shape → `NormalizedOffer`). This is
   the most failure-prone seam in a new provider.
4. Register it in `Docker/supabase/functions/deal-search/registry.ts`:
   ```ts
   import { provider as yourId } from '../_shared/providers/deal-source/<your-id>.ts'
   export const builtinProviders: Record<string, DealSourceProvider> = { marktguru, '<your-id>': yourId }
   ```
5. Add UI metadata to `management-frontend/app/composables/useProviderSettings.ts`'s
   `BUILTIN_PROVIDERS` map so companies can see and toggle it in
   Settings → Extensions.
6. `deno test Docker/supabase/functions/_shared/providers/deal-source/<your-id>.test.ts`
   and open a PR.

No provider_settings migration needed — the table is generic and already
exists; your provider just becomes selectable in the UI once registered.

### Don't want to touch this repo at all?

Run your own HTTPS endpoint and configure it as a **webhook provider** from
Settings → Extensions → `<extension point>` → Add webhook. VMflow calls it
like this:

```http
POST {your_url}
Authorization: Bearer {token_you_chose}
Content-Type: application/json

{
  "version": 1,
  "extensionPoint": "deal-source",
  "method": "fetchOffers",
  "args": { "query": "Monster", "zipCode": "60487" }
}
```

You respond with the same shape a built-in provider would return (for
`deal-source`, a `NormalizedOffer[]` — see the extension point's doc for the
exact fields). Trust model: the auth token is yours, VMflow stores it
encrypted and forwards it as a bearer token; VMflow does not sign requests
or authenticate responses beyond requiring `https://`; you own your own
uptime and auth. Per-call timeout is 10 seconds, no retries — a failing
webhook is skipped and logged, it doesn't take the feature down for other
providers.

## Adding a brand-new extension point

Every extension point follows the same four-part structure. Use `deal-source`
as your reference throughout — it's the only fully-built example in the repo.

1. **Define the interface** in
   `Docker/supabase/functions/_shared/providers/<extension-point>.ts` — a
   context type (whatever inputs your feature needs to hand a provider) and
   a provider interface (the method(s) a provider must implement, and what
   they return). Keep the context extension-point-specific; there's no
   shared generic context type.
2. **Extract the first (existing, hardcoded) implementation** into
   `Docker/supabase/functions/_shared/providers/<extension-point>/<id>.ts` as
   your reference built-in provider. Matching/scoring/caching/merge logic
   that operates on *already-normalized* results stays in the consuming edge
   function — only the fetch-and-normalize step becomes a provider.
3. **Reuse the generic webhook caller** — `_shared/providers/webhook.ts` —
   rather than writing a new one. It already implements the trust model
   (10s timeout, no retry, bearer token, `version: 1` envelope) for any
   extension point.
4. **No new migration needed for activation** — `provider_settings` (see
   `Docker/supabase/migrations/20260505100000_provider_settings.sql`) is
   already generic across extension points:
   ```sql
   -- one row per (company, extension_point, provider_id)
   provider_settings (company_id, extension_point, provider_id, enabled, config, display_name)
   ```
   Your consuming edge function just queries it with your new
   `extension_point` string.
5. **Runtime resolution** in the consuming function: load enabled rows for
   `(company_id, your_extension_point)`, dispatch built-ins by `provider_id`
   lookup and everything prefixed `webhook-` through the generic webhook
   caller, call all active providers concurrently
   (`Promise.allSettled`, 10s timeout each), and merge with
   extension-point-specific logic (dedup/ranking rules live here, not in the
   provider pattern itself).
6. **Admin UI** under Settings → Extensions: a landing page listing
   extension points, and a per-extension-point page with built-in-provider
   toggles plus a shared "add webhook" form (name, `https://` URL, auth
   token, free-form JSON config, and a "test call" button so customers can
   verify a webhook works at config time).
7. **Write the doc** — copy the structure of
   [`docs/extension-points/deal-source.md`](docs/extension-points/deal-source.md):
   what it's for, the interface (inline, commented), a link to the reference
   provider, the webhook contract with a full example, local-testing
   commands, and a copy-paste Claude Code prompt for scaffolding a new
   provider against your new extension point.

Ship the migration (if any), the refactored consuming function, and the
admin UI together — this repo deploys `Docker/` and `management-frontend/`
as one unit, so there's no inter-service deploy-skew window to manage.

## Contributing with Claude Code

Every extension point's doc ends with a ready-to-paste prompt for scaffolding
a new provider in one shot — see the bottom of
[`docs/extension-points/deal-source.md`](docs/extension-points/deal-source.md#contributing-with-claude-code)
for the exact wording to reuse against a new extension point.
