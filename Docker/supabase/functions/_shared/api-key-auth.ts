/**
 * Shared API key authentication helpers.
 * Used by: api-v1 gateway, send-credit, create-api-key
 */

/** SHA-256 hash an API key to hex string for db lookup. */
export async function hashKey(key: string): Promise<string> {
  const encoded = new TextEncoder().encode(key)
  const hash = await crypto.subtle.digest('SHA-256', encoded)
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

/**
 * Validate an API key against the api_keys table.
 * Returns { id, company_id, rate_limit } on success, or throws with status + message.
 *
 * @param apiKey  The raw API key from X-API-Key header
 * @param adminClient  Supabase client with service_role (bypasses RLS)
 */
export async function validateApiKey(
  apiKey: string,
  adminClient: { from: (table: string) => any },
): Promise<{ id: string; company_id: string; rate_limit: number }> {
  const keyHash = await hashKey(apiKey)

  const { data: keyData, error: keyError } = await adminClient
    .from('api_keys')
    .select('id, company_id, revoked_at, rate_limit')
    .eq('key_hash', keyHash)
    .maybeSingle()

  if (keyError || !keyData) {
    throw Object.assign(new Error('Invalid API key'), { status: 401 })
  }
  if (keyData.revoked_at) {
    throw Object.assign(new Error('API key has been revoked'), { status: 401 })
  }

  // Fire-and-forget: update last_used_at
  adminClient
    .from('api_keys')
    .update({ last_used_at: new Date().toISOString() })
    .eq('id', keyData.id)
    .then(() => {}, () => {})

  return {
    id: keyData.id,
    company_id: keyData.company_id,
    rate_limit: keyData.rate_limit ?? 100,
  }
}
