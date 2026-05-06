// Generic HTTP caller for custom webhook providers used by any extension point.
// Contract:
//   POST {url}
//   Authorization: Bearer {authToken}
//   Content-Type: application/json
//   { version: 1, extensionPoint, method, args }
//
// Returns the parsed JSON body. Throws on:
//   - non-https URLs (defense-in-depth on top of admin-UI validation)
//   - non-2xx responses
//   - malformed JSON bodies
//   - network errors / timeout
//
// Callers (per-extension-point resolvers) catch and skip individual failures.

export interface WebhookCallParams {
  /** Full https URL of the customer-hosted webhook. */
  url: string
  /** Customer-chosen auth token, sent as `Authorization: Bearer ...`. */
  authToken: string
  /** Extension-point id, e.g. 'deal-source'. */
  extensionPoint: string
  /** Method on the extension-point interface, e.g. 'fetchOffers'. */
  method: string
  /** Call-specific arguments — must NOT include companyId or provider config. */
  args: Record<string, unknown>
  /** Per-call timeout. Default 10_000 ms. */
  timeoutMs?: number
  /**
   * Test-only escape hatch to use http:// URLs. Production callers must not
   * set this; the HTTPS check is defense-in-depth on top of admin-UI validation.
   */
  __allowInsecureForTests?: boolean
}

export async function callWebhookProvider(params: WebhookCallParams): Promise<unknown> {
  const {
    url,
    authToken,
    extensionPoint,
    method,
    args,
    timeoutMs = 10_000,
    __allowInsecureForTests = false,
  } = params

  if (!__allowInsecureForTests && !url.startsWith('https://')) {
    throw new Error(`webhook url must use https: got ${url}`)
  }

  const controller = new AbortController()
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs)

  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${authToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ version: 1, extensionPoint, method, args }),
      signal: controller.signal,
    })

    if (!res.ok) {
      // Drain the body so the underlying ReadableStream is released; otherwise
      // Deno's resource tracker reports a leak when the caller throws/returns
      // without consuming it.
      try {
        await res.body?.cancel()
      } catch {
        // ignore — best-effort cleanup
      }
      throw new Error(`webhook ${url} returned ${res.status} ${res.statusText}`)
    }

    try {
      return await res.json()
    } catch (jsonErr) {
      throw new Error(`webhook ${url} returned malformed JSON: ${jsonErr}`)
    }
  } finally {
    clearTimeout(timeoutId)
  }
}
