export default defineNuxtRouteMiddleware(async () => {
  // Client-only: the Supabase URL is rewritten in a .client plugin, so SSR
  // RPC calls would hit the wrong host (mirrors middleware/auth.ts).
  if (import.meta.server) return

  const { isPlatformAdmin, checkIsPlatformAdmin } = usePlatformAdmin()
  if (isPlatformAdmin.value) return

  const ok = await checkIsPlatformAdmin()
  if (!ok) return navigateTo('/')
})
