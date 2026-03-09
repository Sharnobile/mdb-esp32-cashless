/// <reference lib="webworker" />
import { precacheAndRoute, cleanupOutdatedCaches } from 'workbox-precaching'

declare let self: ServiceWorkerGlobalScope

// ─── Precache: only offline.html (configured via globPatterns in nuxt.config) ─
// We intentionally limit precaching to avoid all-or-nothing failures that
// prevent SW activation and break push notifications.
cleanupOutdatedCaches()
precacheAndRoute(self.__WB_MANIFEST)

// ─── Lifecycle: activate immediately ────────────────────────────────────────
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()))

// ─── Offline fallback for navigation requests ───────────────────────────────
self.addEventListener('fetch', (event) => {
  if (event.request.mode !== 'navigate') return

  event.respondWith(
    fetch(event.request).catch(async () => {
      // Try to serve the precached offline page
      const cache = await caches.open('workbox-precache-v2')
      const keys = await cache.keys()
      const offlineKey = keys.find((k) => new URL(k.url).pathname.endsWith('/offline'))
      if (offlineKey) {
        const response = await cache.match(offlineKey)
        if (response) return response
      }
      return Response.error()
    }),
  )
})

// ─── SKIP_WAITING message handler (for app update flow) ─────────────────────
self.addEventListener('message', (event) => {
  if (event.data?.type === 'SKIP_WAITING') {
    self.skipWaiting()
  }
})

// ─── Push notification handler ──────────────────────────────────────────────
self.addEventListener('push', (event) => {
  if (!event.data) return

  let payload: { title?: string; body?: string; icon?: string; image?: string; data?: Record<string, unknown> }
  try {
    payload = event.data.json()
  } catch {
    payload = { title: 'VMflow', body: event.data.text() }
  }

  const title = payload.title ?? 'VMflow'
  const options: NotificationOptions = {
    body: payload.body ?? '',
    icon: payload.image ?? payload.icon,
    badge: undefined,
    image: payload.image,
    data: payload.data ?? {},
    tag: payload.data?.type ? String(payload.data.type) : undefined,
  }

  event.waitUntil(self.registration.showNotification(title, options))
})

// ─── Notification click handler ─────────────────────────────────────────────
self.addEventListener('notificationclick', (event) => {
  event.notification.close()

  const data = event.notification.data as Record<string, unknown> | undefined

  // Determine target URL based on notification type
  let targetUrl = '/'
  if (data?.type === 'sale' && data?.embedded_id) {
    targetUrl = `/machines`
  } else if (data?.type === 'low_stock' && data?.machine_id) {
    targetUrl = `/machines/${data.machine_id}`
  }

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if (new URL(client.url).origin === self.location.origin && 'focus' in client) {
          client.focus()
          client.navigate(targetUrl)
          return
        }
      }
      return self.clients.openWindow(targetUrl)
    }),
  )
})
