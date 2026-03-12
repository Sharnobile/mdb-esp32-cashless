export interface SuggestedImage {
  thumbnail: string
  image: string
  title: string
}

export function useProductImageSearch() {
  const supabase = useSupabaseClient()
  const images = ref<SuggestedImage[]>([])
  const searching = ref(false)
  const error = ref('')
  const cache = new Map<string, SuggestedImage[]>()

  let debounceTimer: ReturnType<typeof setTimeout> | null = null

  async function searchImages(query: string) {
    const q = query.trim()
    if (!q || q.length < 2) {
      images.value = []
      return
    }

    // Check cache
    if (cache.has(q)) {
      images.value = cache.get(q)!
      return
    }

    searching.value = true
    error.value = ''
    try {
      const { data, error: fnError } = await (supabase as any).functions.invoke('search-product-images', {
        body: { query: q },
      })
      if (fnError) throw fnError
      const results = data?.images ?? []
      cache.set(q, results)
      images.value = results
    } catch (err: any) {
      error.value = err.message ?? 'Search failed'
      images.value = []
    } finally {
      searching.value = false
    }
  }

  function searchDebounced(query: string) {
    if (debounceTimer) clearTimeout(debounceTimer)
    debounceTimer = setTimeout(() => searchImages(query), 500)
  }

  async function downloadImage(imageUrl: string): Promise<File | null> {
    try {
      // Use direct fetch instead of supabase.functions.invoke
      // because invoke doesn't handle binary image responses correctly
      const { data: { session } } = await (supabase as any).auth.getSession()
      const token = session?.access_token ?? ''
      const config = useRuntimeConfig()
      const baseUrl = config.public.supabase?.url ?? ''

      const response = await fetch(`${baseUrl}/functions/v1/search-product-images`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${token}`,
        },
        body: JSON.stringify({ downloadUrl: imageUrl }),
      })

      if (!response.ok) return null

      const blob = await response.blob()
      if (!blob.size) return null

      const ext = blob.type.includes('png') ? 'png' : blob.type.includes('webp') ? 'webp' : 'jpg'
      return new File([blob], `product.${ext}`, { type: blob.type || 'image/jpeg' })
    } catch {
      return null
    }
  }

  function clear() {
    images.value = []
    error.value = ''
    if (debounceTimer) clearTimeout(debounceTimer)
  }

  return { images, searching, error, searchDebounced, downloadImage, clear }
}
