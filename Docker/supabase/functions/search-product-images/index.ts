import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; rv:102.0) Gecko/20100101 Firefox/102.0'

interface ImageResult {
  thumbnail: string
  image: string
  title: string
}

async function getVqd(query: string): Promise<string> {
  const response = await fetch('https://duckduckgo.com/', {
    method: 'POST',
    headers: { 'User-Agent': USER_AGENT },
    body: new URLSearchParams({ q: query }),
  })
  const text = await response.text()

  // Try multiple vqd extraction patterns
  const patterns = [
    /vqd='([^']+)'/,
    /vqd="([^"]+)"/,
    /vqd=([\d-]+)&/,
  ]
  for (const pattern of patterns) {
    const match = text.match(pattern)
    if (match?.[1]) return match[1]
  }
  throw new Error('Failed to extract VQD token')
}

async function searchImages(query: string): Promise<ImageResult[]> {
  const vqd = await getVqd(query)
  const params = new URLSearchParams({
    q: query,
    o: 'json',
    l: 'wt-wt',
    s: '0',
    f: ',,,type:photo,,',
    p: '1',
    vqd,
  })

  const response = await fetch(`https://duckduckgo.com/i.js?${params}`, {
    headers: {
      'User-Agent': USER_AGENT,
      'Referer': 'https://duckduckgo.com/',
      'Accept-Language': 'en-US,en;q=0.9',
    },
  })

  if (!response.ok) {
    throw new Error(`DuckDuckGo returned ${response.status}`)
  }

  const data = await response.json()
  const results = (data.results ?? []).slice(0, 8)

  return results.map((r: any) => ({
    thumbnail: r.thumbnail ?? '',
    image: r.image ?? '',
    title: r.title ?? '',
  }))
}

async function proxyImage(url: string): Promise<Response> {
  const response = await fetch(url, {
    headers: { 'User-Agent': USER_AGENT },
  })

  if (!response.ok) {
    return new Response(JSON.stringify({ error: 'Failed to fetch image' }), {
      status: 502,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  const contentType = response.headers.get('Content-Type') ?? 'image/jpeg'
  const body = await response.arrayBuffer()

  return new Response(body, {
    status: 200,
    headers: {
      ...corsHeaders,
      'Content-Type': contentType,
      'Cache-Control': 'public, max-age=86400',
    },
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders })
  }

  try {
    // Auth check
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )
    const token = req.headers.get('Authorization')?.replace('Bearer ', '') ?? ''
    const { data: { user }, error: userError } = await adminClient.auth.getUser(token)
    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const body = await req.json()

    // Mode 1: Search images
    if (body.query) {
      const query = String(body.query).trim()
      if (!query || query.length > 200) {
        return new Response(JSON.stringify({ error: 'Invalid query' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      const images = await searchImages(query)
      return new Response(JSON.stringify({ images }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // Mode 2: Proxy/download image
    if (body.downloadUrl) {
      const url = String(body.downloadUrl)
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        return new Response(JSON.stringify({ error: 'Invalid URL' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }
      return await proxyImage(url)
    }

    return new Response(JSON.stringify({ error: 'Provide query or downloadUrl' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    console.error('search-product-images error:', err)
    return new Response(JSON.stringify({ error: err?.message ?? 'Internal error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
