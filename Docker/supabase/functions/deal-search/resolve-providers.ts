// Resolves per-company provider_settings rows into runtime DealSourceProviders.
//
// Built-in IDs hit the static registry. Webhook IDs (prefix 'webhook-') wrap
// the generic webhook caller. Unknown IDs log a warning and are skipped —
// this happens when a row outlives a built-in provider that was removed from
// the codebase, or when a typo creeps into an admin-UI edit.

import type {
  DealSourceContext,
  DealSourceProvider,
  NormalizedOffer,
} from '../_shared/providers/deal-source.ts'
import { callWebhookProvider } from '../_shared/providers/webhook.ts'
import { builtinProviders } from './registry.ts'

export interface ProviderRow {
  provider_id: string
  config: Record<string, unknown>
}

export interface ResolvedProvider {
  provider: DealSourceProvider
  /** The raw row so callers can access provider-specific config if they need to. */
  row: ProviderRow
}

export async function resolveProviders(
  // deno-lint-ignore no-explicit-any
  adminClient: any,
  companyId: string,
): Promise<ResolvedProvider[]> {
  const { data, error } = await adminClient
    .from('provider_settings')
    .select('provider_id, config')
    .eq('company_id', companyId)
    .eq('extension_point', 'deal-source')
    .eq('enabled', true)

  if (error) throw error

  const result: ResolvedProvider[] = []
  for (const row of (data ?? []) as ProviderRow[]) {
    const builtin = builtinProviders[row.provider_id]
    if (builtin) {
      result.push({ provider: builtin, row })
      continue
    }

    if (row.provider_id.startsWith('webhook-')) {
      const cfg = row.config as { url?: string; authToken?: string }
      if (!cfg.url || !cfg.authToken) {
        console.warn(
          `[deal-search] webhook provider ${row.provider_id} missing url or authToken; skipping`,
        )
        continue
      }
      result.push({
        provider: makeWebhookProvider(row.provider_id, cfg.url, cfg.authToken),
        row,
      })
      continue
    }

    console.warn(`[deal-search] unknown provider ${row.provider_id}; skipping`)
  }
  return result
}

function makeWebhookProvider(
  id: string,
  url: string,
  authToken: string,
): DealSourceProvider {
  return {
    id,
    async fetchOffers(query: string, ctx: DealSourceContext): Promise<NormalizedOffer[]> {
      const out = await callWebhookProvider({
        url,
        authToken,
        extensionPoint: 'deal-source',
        method: 'fetchOffers',
        // companyId and config are deliberately omitted — see spec
        args: { query, zipCode: ctx.zipCode },
      })
      // Trust the webhook's output shape per the loose contract; arrays only.
      return Array.isArray(out) ? (out as NormalizedOffer[]) : []
    },
  }
}
