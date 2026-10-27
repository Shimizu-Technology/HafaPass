import { clientsClaim } from 'workbox-core'
import { enable as enableNavigationPreload } from 'workbox-navigation-preload'
import { cleanupOutdatedCaches, matchPrecache, precacheAndRoute } from 'workbox-precaching'
import { registerRoute } from 'workbox-routing'
import { CacheFirst, NetworkFirst, NetworkOnly, StaleWhileRevalidate } from 'workbox-strategies'
import { ExpirationPlugin } from 'workbox-expiration'
import buildRuntimeCaching from './config/pwaRuntimeCaching.js'

self.skipWaiting()
clientsClaim()
enableNavigationPreload()

const offlineDocument = request => matchPrecache(
  new URL(request.url).pathname === '/offline.html' ? '/offline.html' : '/index.html',
)

// Register BEFORE precacheAndRoute: its directory-index matching would
// otherwise serve stale HTML for / and /index.html even while online.
registerRoute(
  ({ request, url }) => request.mode === 'navigate'
    && url.origin === self.location.origin
    && !/^\/api/.test(url.pathname)
    && !/^\/(?:robots\.txt|sitemap\.xml)$/.test(url.pathname)
    && !/^\/assets\//.test(url.pathname),
  new NetworkFirst({
    cacheName: 'hafapass-navigation',
    networkTimeoutSeconds: 3,
    plugins: [{
      // Always fall back to the installed shell and its matching assets. A
      // later network shell may reference chunks this worker hasn't installed.
      // This hook also supplies the timeout response on a never-visited URL;
      // NetworkFirst otherwise keeps waiting after a timeout/cache miss.
      cachedResponseWillBeUsed: async ({ request }) => offlineDocument(request),
      cacheWillUpdate: async () => null,
      // Preloaded responses bypass fetchDidSucceed in Workbox. Validate at
      // response delivery so a server outage also works with preload enabled.
      handlerWillRespond: async ({ request, response }) => response.status >= 500
        ? offlineDocument(request) : response,
    }],
  }),
)

precacheAndRoute(self.__WB_MANIFEST)
cleanupOutdatedCaches()

// Preserve the existing API/image/font policies with the same shared config.
const strategies = { CacheFirst, NetworkOnly, StaleWhileRevalidate }
for (const { urlPattern, handler, options = {} } of buildRuntimeCaching(import.meta.env.VITE_API_URL)) {
  const { expiration, ...strategyOptions } = options
  registerRoute(urlPattern, new strategies[handler]({
    ...strategyOptions,
    ...(expiration ? { plugins: [new ExpirationPlugin(expiration)] } : {}),
  }))
}
