/**
 * Fallback service worker registration.
 *
 * The @vite-pwa/nuxt plugin should register the SW automatically via
 * `injectRegister: 'auto'`, but in production this can fail silently.
 * This plugin ensures the SW gets registered regardless.
 */
export default defineNuxtPlugin(() => {
  if (!('serviceWorker' in navigator)) return

  // Wait for page load so SW registration doesn't compete with initial resources
  window.addEventListener('load', async () => {
    try {
      const registrations = await navigator.serviceWorker.getRegistrations()
      if (registrations.length > 0) return // already registered

      console.info('[register-sw] No SW found — registering /sw.js')
      await navigator.serviceWorker.register('/sw.js', { scope: '/' })
    } catch (err) {
      console.warn('[register-sw] Registration failed:', err)
    }
  })
})
