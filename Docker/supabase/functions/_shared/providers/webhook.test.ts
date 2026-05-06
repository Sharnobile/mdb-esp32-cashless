/**
 * Tests for the generic webhook caller used by every extension point.
 *
 * Run: deno test Docker/supabase/functions/_shared/providers/webhook.test.ts \
 *        --allow-net
 */

import { assertEquals, assertRejects, assertStringIncludes } from 'jsr:@std/assert'
import { callWebhookProvider } from './webhook.ts'

// ── Helpers ───────────────────────────────────────────────────────────────────

interface CapturedRequest {
  method: string
  headers: Headers
  body: unknown
}

/**
 * Stand up a one-shot HTTP listener that captures the request and replies with
 * the configured handler. Returns the listener URL plus the captured request.
 *
 * Note: In Deno 2.7+ the Request object is invalidated once the handler resolves
 * and the response stream is drained. We therefore snapshot method, headers, and
 * (best-effort) the parsed JSON body INSIDE the handler before the response is
 * returned, so test assertions can run after the server is shut down.
 */
async function withServer(
  handler: (req: Request) => Promise<Response> | Response,
  block: (
    url: string,
    captured: { value: CapturedRequest | null },
  ) => Promise<void>,
) {
  const captured: { value: CapturedRequest | null } = { value: null }
  const ac = new AbortController()
  const server = Deno.serve(
    { port: 0, signal: ac.signal, onListen: () => {} },
    async (req) => {
      // Snapshot before the handler completes — Request becomes inert after.
      const headers = new Headers(req.headers)
      const method = req.method
      let body: unknown = undefined
      try {
        // Best-effort: tests that send JSON expect this to parse.
        body = await req.clone().json()
      } catch {
        // Non-JSON body, ignore.
      }
      captured.value = { method, headers, body }
      return handler(req)
    },
  )
  // @ts-ignore Deno.serve typing exposes addr at runtime
  const port = server.addr.port as number
  try {
    await block(`http://127.0.0.1:${port}`, captured)
  } finally {
    ac.abort()
    await server.finished
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

Deno.test('callWebhookProvider rejects http:// URLs (https-only enforcement)', async () => {
  await assertRejects(
    () =>
      callWebhookProvider({
        url: 'http://example.com/hook',
        authToken: 't',
        extensionPoint: 'deal-source',
        method: 'fetchOffers',
        args: { query: 'x', zipCode: '60487' },
      }),
    Error,
    'https',
  )
})

Deno.test('callWebhookProvider posts versioned envelope with bearer auth', async () => {
  await withServer(
    () =>
      new Response(JSON.stringify([{ externalId: '1', retailer: 'X' }]), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    async (url, captured) => {
      const result = await callWebhookProvider({
        url,
        authToken: 'secret',
        extensionPoint: 'deal-source',
        method: 'fetchOffers',
        args: { query: 'Monster', zipCode: '60487' },
        __allowInsecureForTests: true,
      })
      assertEquals(Array.isArray(result), true)
      const req = captured.value!
      assertEquals(req.method, 'POST')
      assertEquals(req.headers.get('authorization'), 'Bearer secret')
      assertEquals(req.headers.get('content-type'), 'application/json')
      const body = req.body as Record<string, unknown> & {
        args: Record<string, unknown>
      }
      assertEquals(body.version, 1)
      assertEquals(body.extensionPoint, 'deal-source')
      assertEquals(body.method, 'fetchOffers')
      assertEquals(body.args.query, 'Monster')
      assertEquals(body.args.zipCode, '60487')
    },
  )
})

Deno.test('callWebhookProvider throws on non-2xx responses', async () => {
  await withServer(
    () => new Response('boom', { status: 500 }),
    async (url) => {
      await assertRejects(
        () =>
          callWebhookProvider({
            url,
            authToken: 't',
            extensionPoint: 'deal-source',
            method: 'fetchOffers',
            args: {},
            __allowInsecureForTests: true,
          }),
        Error,
        '500',
      )
    },
  )
})

Deno.test('callWebhookProvider throws on malformed JSON body', async () => {
  await withServer(
    () =>
      new Response('{not json', {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    async (url) => {
      const err = await assertRejects(
        () =>
          callWebhookProvider({
            url,
            authToken: 't',
            extensionPoint: 'deal-source',
            method: 'fetchOffers',
            args: {},
            __allowInsecureForTests: true,
          }),
      )
      assertStringIncludes(String(err), 'JSON')
    },
  )
})

Deno.test('callWebhookProvider aborts after the configured timeout', async () => {
  // Track the server-side delay timer so we can clear it when the request is
  // aborted client-side, otherwise Deno's leak detector flags the leftover
  // setTimeout (the test exits before the 500ms delay fires).
  let pendingDelay: number | undefined
  await withServer(
    (req) =>
      new Promise<Response>((resolve, reject) => {
        pendingDelay = setTimeout(
          () => resolve(new Response('late', { status: 200 })),
          500,
        )
        req.signal.addEventListener('abort', () => {
          if (pendingDelay !== undefined) clearTimeout(pendingDelay)
          reject(new Error('aborted'))
        })
      }),
    async (url) => {
      const err = await assertRejects(
        () =>
          callWebhookProvider({
            url,
            authToken: 't',
            extensionPoint: 'deal-source',
            method: 'fetchOffers',
            args: {},
            timeoutMs: 50,
            __allowInsecureForTests: true,
          }),
      )
      const msg = String(err).toLowerCase()
      assertEquals(
        msg.includes('abort') || msg.includes('timeout'),
        true,
        `expected abort/timeout in error, got: ${err}`,
      )
    },
  )
})
