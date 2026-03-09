/**
 * Service worker registration.
 *
 * Registers the plain /sw.js (push-only, no workbox).
 * Unregisters any stale workbox-generated SWs first to prevent
 * "redundant" state on iOS when the cached old SW fails to install.
 */
export default defineNuxtPlugin(() => {
  if (!('serviceWorker' in navigator)) return

  window.addEventListener('load', async () => {
    try {
      // Unregister any existing SWs that aren't our plain /sw.js
      // (e.g. old workbox-generated SWs cached by the browser)
      const registrations = await navigator.serviceWorker.getRegistrations()
      for (const reg of registrations) {
        const swUrl = (reg.active ?? reg.waiting ?? reg.installing)?.scriptURL ?? ''
        if (!swUrl.endsWith('/sw.js')) {
          console.info('[register-sw] Unregistering stale SW:', swUrl)
          await reg.unregister()
        }
      }

      // Register with updateViaCache: 'none' to bypass HTTP cache
      // and always fetch the latest SW file from the server
      console.info('[register-sw] Registering /sw.js')
      await navigator.serviceWorker.register('/sw.js', {
        scope: '/',
        updateViaCache: 'none',
      })
    } catch (err) {
      console.warn('[register-sw] Registration failed:', err)
    }
  })
})
