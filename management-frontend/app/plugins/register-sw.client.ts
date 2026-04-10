/**
 * Service worker registration.
 *
 * Registers the plain /sw.js (push-only, no workbox).
 * If no SW is actively controlling the page, unregisters ALL existing
 * SWs first (including stale workbox-generated ones at the same URL)
 * to get a clean slate.
 *
 * In dev mode the SW is NEVER registered: Vite serves JS/CSS with
 * ever-changing query params and hot-swaps modules, which is fundamentally
 * incompatible with cache-first runtime caching. Any SW already installed
 * from a previous dev session is actively unregistered so currently-broken
 * clients recover on next reload.
 */
export default defineNuxtPlugin(() => {
  if (!('serviceWorker' in navigator)) return

  window.addEventListener('load', async () => {
    try {
      if (import.meta.dev) {
        // Dev mode: tear down any SW + caches left over from a prior dev
        // or prod session. A cached Vite asset served stale causes white
        // screens on normal reload (only CMD+SHIFT+R recovers).
        const registrations = await navigator.serviceWorker.getRegistrations()
        if (registrations.length > 0) {
          for (const reg of registrations) {
            const url = (reg.active ?? reg.waiting ?? reg.installing)?.scriptURL
            console.info('[register-sw] dev mode — unregistering SW:', url)
            await reg.unregister()
          }
          if ('caches' in window) {
            const names = await caches.keys()
            await Promise.all(names.map((n) => caches.delete(n)))
          }
        }
        return
      }

      // If we already have an active controller, SW is working fine
      if (navigator.serviceWorker.controller) {
        console.info('[register-sw] SW already active')
        return
      }

      // No active controller — clean slate: unregister everything
      // (the old workbox SW was also at /sw.js, so URL checks don't help)
      const registrations = await navigator.serviceWorker.getRegistrations()
      for (const reg of registrations) {
        const url = (reg.active ?? reg.waiting ?? reg.installing)?.scriptURL
        console.info('[register-sw] Unregistering stale SW:', url)
        await reg.unregister()
      }

      // Register fresh with cache bypass
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
