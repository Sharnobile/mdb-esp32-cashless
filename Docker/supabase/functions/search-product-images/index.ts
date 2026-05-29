import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { decode, Image } from 'https://deno.land/x/imagescript@1.3.0/mod.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; rv:102.0) Gecko/20100101 Firefox/102.0'

const PAGE_SIZE = 8
// Downscale downloaded suggestions so stored product images stay small.
const MAX_IMAGE_DIM = 600
const JPEG_QUALITY = 80

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

async function searchImages(query: string, offset: number): Promise<{ images: ImageResult[]; hasMore: boolean }> {
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
  const all = (data.results ?? []) as any[]
  // Page server-side from the full result list so arbitrary offsets are exact,
  // independent of how DuckDuckGo's own `s` cursor snaps.
  const page = all.slice(offset, offset + PAGE_SIZE)

  return {
    images: page.map((r: any) => ({
      thumbnail: r.thumbnail ?? '',
      image: r.image ?? '',
      title: r.title ?? '',
    })),
    hasMore: all.length > offset + PAGE_SIZE,
  }
}

// Decode, downscale to MAX_IMAGE_DIM on the longest edge, re-encode as JPEG.
// Returns null on any failure so the caller falls back to the original bytes.
async function shrinkImage(bytes: Uint8Array): Promise<Uint8Array | null> {
  try {
    const decoded = await decode(bytes)
    if (!(decoded instanceof Image)) return null // skip animated GIFs etc.
    let img = decoded
    const longest = Math.max(img.width, img.height)
    if (longest > MAX_IMAGE_DIM) {
      img = img.width >= img.height
        ? img.resize(MAX_IMAGE_DIM, Image.RESIZE_AUTO)
        : img.resize(Image.RESIZE_AUTO, MAX_IMAGE_DIM)
    }
    return await img.encodeJPEG(JPEG_QUALITY)
  } catch {
    return null
  }
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

  const originalType = response.headers.get('Content-Type') ?? 'image/jpeg'
  const originalBytes = new Uint8Array(await response.arrayBuffer())

  const shrunk = await shrinkImage(originalBytes)
  const body = shrunk ?? originalBytes
  const contentType = shrunk ? 'image/jpeg' : originalType

  return new Response(body as BodyInit, {
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

      const rawOffset = Number(body.offset ?? 0)
      const offset = Number.isFinite(rawOffset) && rawOffset > 0 ? Math.floor(rawOffset) : 0

      const { images, hasMore } = await searchImages(query, offset)
      return new Response(JSON.stringify({ images, hasMore }), {
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
    return new Response(JSON.stringify({ error: (err as any)?.message ?? 'Internal error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
