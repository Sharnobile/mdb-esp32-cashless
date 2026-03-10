import { Capacitor } from '@capacitor/core'

export default defineNuxtPlugin(() => {
  if (!Capacitor.isNativePlatform()) return

  // Configure status bar for native apps
  import('@capacitor/status-bar').then(({ StatusBar, Style }) => {
    StatusBar.setStyle({ style: Style.Default })
  }).catch(() => {})

  // Handle deep links (notification clicks, shared URLs)
  import('@capacitor/app').then(({ App }) => {
    App.addListener('appUrlOpen', ({ url }) => {
      try {
        const path = new URL(url).pathname
        navigateTo(path)
      } catch {
        // Invalid URL, ignore
      }
    })
  }).catch(() => {})
})
