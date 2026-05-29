export interface SuggestedImage {
  thumbnail: string
  image: string
  title: string
}

const PAGE_SIZE = 8

interface ImagePage {
  images: SuggestedImage[]
  hasMore: boolean
}

export function useProductImageSearch() {
  const supabase = useSupabaseClient()
  const images = ref<SuggestedImage[]>([])
  const searching = ref(false)
  const loadingMore = ref(false)
  const hasMore = ref(false)
  const error = ref('')
  const cache = new Map<string, ImagePage>()

  let debounceTimer: ReturnType<typeof setTimeout> | null = null
  let currentQuery = ''
  let currentOffset = 0

  async function fetchPage(q: string, offset: number): Promise<ImagePage> {
    const cacheKey = `${q}|${offset}`
    if (cache.has(cacheKey)) return cache.get(cacheKey)!

    const { data, error: fnError } = await (supabase as any).functions.invoke('search-product-images', {
      body: { query: q, offset },
    })
    if (fnError) throw fnError
    const page: ImagePage = { images: data?.images ?? [], hasMore: data?.hasMore ?? false }
    cache.set(cacheKey, page)
    return page
  }

  async function searchImages(query: string) {
    const q = query.trim()
    if (!q || q.length < 2) {
      images.value = []
      hasMore.value = false
      currentQuery = ''
      return
    }

    currentQuery = q
    currentOffset = 0
    searching.value = true
    error.value = ''
    try {
      const page = await fetchPage(q, 0)
      images.value = page.images
      hasMore.value = page.hasMore
    } catch (err: any) {
      error.value = err.message ?? 'Search failed'
      images.value = []
      hasMore.value = false
    } finally {
      searching.value = false
    }
  }

  async function loadMore() {
    if (!currentQuery || loadingMore.value || !hasMore.value) return
    loadingMore.value = true
    error.value = ''
    try {
      const nextOffset = currentOffset + PAGE_SIZE
      const page = await fetchPage(currentQuery, nextOffset)
      currentOffset = nextOffset
      const seen = new Set(images.value.map(i => i.image))
      images.value = [...images.value, ...page.images.filter(i => !seen.has(i.image))]
      hasMore.value = page.hasMore
    } catch (err: any) {
      error.value = err.message ?? 'Search failed'
    } finally {
      loadingMore.value = false
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
    hasMore.value = false
    currentQuery = ''
    currentOffset = 0
    if (debounceTimer) clearTimeout(debounceTimer)
  }

  return { images, searching, loadingMore, hasMore, error, searchDebounced, loadMore, downloadImage, clear }
}
