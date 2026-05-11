import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import * as jose from 'https://deno.land/x/jose@v4.14.4/index.ts'

const JWT_SECRET = Deno.env.get('JWT_SECRET')
const VERIFY_JWT = Deno.env.get('VERIFY_JWT') === 'true'

function getAuthToken(req: Request) {
  const authHeader = req.headers.get('authorization')
  if (!authHeader) {
    throw new Error('Missing authorization header')
  }
  const [bearer, token] = authHeader.split(' ')
  if (bearer !== 'Bearer') {
    throw new Error(`Auth header is not 'Bearer {token}'`)
  }
  return token
}

async function verifyJWT(jwt: string): Promise<boolean> {
  const encoder = new TextEncoder()
  const secretKey = encoder.encode(JWT_SECRET)
  try {
    await jose.jwtVerify(jwt, secretKey)
  } catch (err) {
    console.error(err)
    return false
  }
  return true
}

serve(async (req: Request) => {
  if (req.method !== 'OPTIONS' && VERIFY_JWT) {
    try {
      const token = getAuthToken(req)
      const isValidJWT = await verifyJWT(token)

      if (!isValidJWT) {
        return new Response(JSON.stringify({ msg: 'Invalid JWT' }), {
          status: 401,
          headers: { 'Content-Type': 'application/json' },
        })
      }
    } catch (e) {
      console.error(e)
      return new Response(JSON.stringify({ msg: e.toString() }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      })
    }
  }

  const url = new URL(req.url)
  const { pathname } = url
  const path_parts = pathname.split('/')
  const service_name = path_parts[1]

  if (!service_name || service_name === '') {
    const error = { msg: 'missing function name in request' }
    return new Response(JSON.stringify(error), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const servicePath = `/home/deno/functions/${service_name}`

  const memoryLimitMb = 150
  // Heavy fan-out functions (search, AI) routinely exceed the runtime
  // defaults in production:
  //   - deal-search calls N enabled providers across up to 400 queries
  //     (concurrency 10). Wall clock is dominated by the slowest provider
  //     per batch, and parsing ~600 provider JSON responses + matching them
  //     against the catalog blows past the default ~2s CPU-time hard limit.
  //   - machine-insights calls the Anthropic API which can take 30–60s
  //     end-to-end with longer contexts.
  //
  // Bump three independent limits for these functions:
  //   - workerTimeoutMs   wall-clock budget (default 60s)
  //   - cpuTimeSoftLimit  triggers `beforeunload`; soft (default ~1s)
  //   - cpuTimeHardLimit  supervisor kills the isolate; hard (default ~2s)
  //
  // CPU-time-hard hits as:
  //   CPU time hard limit reached: isolate: ...
  //   failed to send request to user worker: request has been cancelled by supervisor
  // surfacing to clients as
  //   {"msg":"WorkerRequestCancelled: request has been cancelled by supervisor"}
  //
  // Other functions keep the defaults so a buggy/runaway worker can't tie
  // up a slot for long.
  const HEAVY_FUNCTIONS = new Set(['deal-search', 'machine-insights'])
  const isHeavy = HEAVY_FUNCTIONS.has(service_name)
  const workerTimeoutMs = isHeavy ? 3 * 60 * 1000 : 1 * 60 * 1000
  const cpuTimeSoftLimitMs = isHeavy ? 100_000 : undefined
  const cpuTimeHardLimitMs = isHeavy ? 150_000 : undefined
  const noModuleCache = false
  const importMapPath = null
  const envVarsObj = Deno.env.toObject()
  const envVars = Object.keys(envVarsObj).map((k) => [k, envVarsObj[k]])

  try {
    const worker = await EdgeRuntime.userWorkers.create({
      servicePath,
      memoryLimitMb,
      workerTimeoutMs,
      cpuTimeSoftLimitMs,
      cpuTimeHardLimitMs,
      noModuleCache,
      importMapPath,
      envVars,
    })
    return await worker.fetch(req)
  } catch (e) {
    const error = { msg: e.toString() }
    return new Response(JSON.stringify(error), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    })
  }
})
