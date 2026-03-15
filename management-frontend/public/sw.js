// v3 — Plain service worker with runtime caching + push notifications.
// No workbox precaching (caused iOS install failures).

var CACHE_NAME = 'vmflow-runtime-v1'

// ─── Lifecycle ───────────────────────────────────────────────────────────────

self.addEventListener('install', function (event) {
  event.waitUntil(self.skipWaiting())
})

self.addEventListener('activate', function (event) {
  // Clean up old caches
  event.waitUntil(
    caches.keys().then(function (names) {
      return Promise.all(
        names
          .filter(function (name) { return name !== CACHE_NAME })
          .map(function (name) { return caches.delete(name) })
      )
    }).then(function () {
      return self.clients.claim()
    })
  )
})

self.addEventListener('message', function (event) {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting()
  }
})

// ─── Runtime caching (fetch handler) ─────────────────────────────────────────

// Static assets: cache-first (JS, CSS, fonts, images have hashed filenames)
var STATIC_EXT = /\.(?:js|css|woff2?|ttf|eot|png|jpe?g|gif|svg|webp|ico|avif)(?:\?|$)/

// Never cache: API calls, auth, realtime, supabase
var NO_CACHE = /(?:\/rest\/|\/auth\/|\/realtime\/|\/functions\/|\/storage\/)/

self.addEventListener('fetch', function (event) {
  var request = event.request

  // Only handle GET requests
  if (request.method !== 'GET') return

  var url = new URL(request.url)

  // Skip cross-origin API/auth requests
  if (url.origin !== self.location.origin) return

  // Skip non-http(s)
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return

  // Skip API-like paths
  if (NO_CACHE.test(url.pathname)) return

  if (STATIC_EXT.test(url.pathname)) {
    // ── Cache-first for static assets ──
    event.respondWith(
      caches.open(CACHE_NAME).then(function (cache) {
        return cache.match(request).then(function (cached) {
          if (cached) return cached
          return fetch(request).then(function (response) {
            if (response.ok) {
              cache.put(request, response.clone())
            }
            return response
          })
        })
      })
    )
  } else if (request.mode === 'navigate') {
    // ── Network-first for navigation (HTML pages) ──
    event.respondWith(
      fetch(request)
        .then(function (response) {
          if (response.ok) {
            caches.open(CACHE_NAME).then(function (cache) {
              cache.put(request, response.clone())
            })
          }
          return response
        })
        .catch(function () {
          return caches.match(request).then(function (cached) {
            return cached || caches.match('/offline')
          })
        })
    )
  }
})

// ─── Push notification handler ───────────────────────────────────────────────

self.addEventListener('push', function (event) {
  if (!event.data) return

  var payload
  try {
    payload = event.data.json()
  } catch (e) {
    payload = { title: 'VMflow', body: event.data.text() }
  }

  var title = payload.title || 'VMflow'
  var options = {
    body: payload.body || '',
    icon: payload.image || payload.icon,
    image: payload.image,
    data: payload.data || {},
    tag: payload.data && payload.data.type ? String(payload.data.type) : undefined,
  }

  event.waitUntil(self.registration.showNotification(title, options))
})

// ─── Notification click handler ──────────────────────────────────────────────

self.addEventListener('notificationclick', function (event) {
  event.notification.close()

  var data = event.notification.data || {}

  var targetUrl = '/'
  if (data.type === 'sale' && data.embedded_id) {
    targetUrl = '/machines'
  } else if (data.type === 'low_stock' && data.machine_id) {
    targetUrl = '/machines/' + data.machine_id
  }

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (clientList) {
      for (var i = 0; i < clientList.length; i++) {
        var client = clientList[i]
        if (new URL(client.url).origin === self.location.origin && 'focus' in client) {
          client.focus()
          client.navigate(targetUrl)
          return
        }
      }
      return self.clients.openWindow(targetUrl)
    })
  )
})
