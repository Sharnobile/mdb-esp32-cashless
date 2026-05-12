export default defineNuxtRouteMiddleware(async (to) => {
  const publicRoutes = [
    '/auth/login',
    '/auth/register',
    '/onboarding/create-organization',
    '/onboarding/accept-invitation',
    '/server-loading',
  ]
  if (publicRoutes.some(route => to.path.startsWith(route))) {
    return
  }
  // Public machine routes: /m (index), /m/[id], /m/o/[company]
  if (to.path === '/m' || to.path.startsWith('/m/')) {
    return
  }
  // Public install page
  if (to.path === '/install') {
    return
  }

  // Use session, not user: in @nuxtjs/supabase v2.0+ useSupabaseUser() is
  // populated asynchronously via getClaims() after onAuthStateChange fires,
  // which loses the race against navigateTo() right after signInWithPassword.
  // useSupabaseSession() is set synchronously in the same listener.
  const session = useSupabaseSession()
  if (!session.value) {
    return navigateTo('/auth/login')
  }

  // Skip org fetch on SSR — the Supabase client URL gets rewritten
  // client-side (supabase-url.client.ts), so server-side calls may fail.
  if (import.meta.server) {
    return
  }

  const { organization, role, fetchError, fetchOrganization } = useOrganization()
  if (organization.value !== null && organization.value !== undefined && role.value !== null) {
    return
  }

  try {
    await fetchOrganization()
    if (!organization.value) {
      return navigateTo('/onboarding/create-organization')
    }
  } catch {
    // Server/network error (502, timeout, etc.) → show loading page
    if (fetchError.value === 'server') {
      return navigateTo('/server-loading')
    }
    // Other errors (auth issues, etc.) → fallback to onboarding
    return navigateTo('/onboarding/create-organization')
  }
})
