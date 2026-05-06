// Per-company CRUD over provider_settings, scoped to one extension point at
// a time. Used by /settings/extensions/* admin pages.

import { useState, useSupabaseClient } from '#imports'

interface ProviderSettingsRow {
  provider_id: string
  enabled: boolean
  config: Record<string, unknown>
  display_name: string | null
}

export interface BuiltinProviderMeta {
  id: string
  label: string                  // display name, e.g. 'Marktguru'
  description: string            // one-line tagline
}

// Frontend-side mirror of the edge-function registry. Keep in sync when adding
// new built-ins (the edge function won't know about UI-side metadata, so we
// duplicate intentionally).
export const BUILTIN_PROVIDERS: Record<'deal-source', BuiltinProviderMeta[]> = {
  'deal-source': [
    {
      id: 'marktguru',
      label: 'Marktguru',
      description: 'Aggregator covering most German retailers (REWE, Lidl, Aldi, …).',
    },
  ],
}

export function useProviderSettings(companyId: string) {
  const supabase = useSupabaseClient()
  const rows = useState<ProviderSettingsRow[]>(`provider-settings-${companyId}`, () => [])
  const loading = useState<boolean>(`provider-settings-loading-${companyId}`, () => false)

  async function load(extensionPoint: string) {
    if (!companyId) return
    loading.value = true
    try {
      const { data, error } = await supabase
        .from('provider_settings')
        .select('provider_id, enabled, config, display_name')
        .eq('company_id', companyId)
        .eq('extension_point', extensionPoint)
      if (error) throw error
      rows.value = (data ?? []) as ProviderSettingsRow[]
    } finally {
      loading.value = false
    }
  }

  async function setEnabled(extensionPoint: string, providerId: string, enabled: boolean) {
    const existing = rows.value.find((r) => r.provider_id === providerId)
    const upsertRow = {
      company_id: companyId,
      extension_point: extensionPoint,
      provider_id: providerId,
      enabled,
      config: existing?.config ?? {},
      display_name: existing?.display_name ?? null,
    }
    const { error } = await supabase.from('provider_settings').upsert([upsertRow])
    if (error) throw error
    if (existing) existing.enabled = enabled
    else rows.value.push({ provider_id: providerId, enabled, config: {}, display_name: null })
  }

  async function addWebhook(
    extensionPoint: string,
    displayName: string,
    url: string,
    authToken: string,
    extraConfig: Record<string, unknown>,
  ) {
    if (!url.startsWith('https://')) {
      throw new Error('Webhook URL must use https://')
    }
    // crypto.randomUUID() requires a secure context. Fallback for LAN-IP dev
    // (http://10.x.x.x:3000 etc., which CLAUDE.md documents as a supported
    // dev pattern) so admins on Safari < 15.4 / non-https origins still work.
    const uuid = crypto.randomUUID?.()
      ?? `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`
    const providerId = `webhook-${uuid}`
    const config = { url, authToken, ...extraConfig }
    const upsertRow = {
      company_id: companyId,
      extension_point: extensionPoint,
      provider_id: providerId,
      enabled: true,
      config,
      display_name: displayName,
    }
    const { error } = await supabase.from('provider_settings').upsert([upsertRow])
    if (error) throw error
    rows.value.push({ provider_id: providerId, enabled: true, config, display_name: displayName })
    return providerId
  }

  async function updateWebhook(
    extensionPoint: string,
    providerId: string,
    patch: { displayName?: string; url?: string; authToken?: string; extraConfig?: Record<string, unknown> },
  ) {
    const existing = rows.value.find((r) => r.provider_id === providerId)
    if (!existing) throw new Error(`unknown provider ${providerId}`)
    if (patch.url && !patch.url.startsWith('https://')) {
      throw new Error('Webhook URL must use https://')
    }
    const newConfig = {
      ...existing.config,
      ...(patch.url ? { url: patch.url } : {}),
      ...(patch.authToken ? { authToken: patch.authToken } : {}),
      ...(patch.extraConfig ?? {}),
    }
    const upsertRow = {
      company_id: companyId,
      extension_point: extensionPoint,
      provider_id: providerId,
      enabled: existing.enabled,
      config: newConfig,
      display_name: patch.displayName ?? existing.display_name,
    }
    const { error } = await supabase.from('provider_settings').upsert([upsertRow])
    if (error) throw error
    existing.config = newConfig
    if (patch.displayName !== undefined) existing.display_name = patch.displayName
  }

  async function removeWebhook(_extensionPoint: string, providerId: string) {
    const { error } = await supabase
      .from('provider_settings')
      .delete()
      .eq('company_id', companyId)
      .eq('provider_id', providerId)
    if (error) throw error
    rows.value = rows.value.filter((r) => r.provider_id !== providerId)
  }

  return { rows, loading, load, setEnabled, addWebhook, updateWebhook, removeWebhook }
}
