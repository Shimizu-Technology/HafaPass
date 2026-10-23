// Run against a production build served by Vite preview on 5221.
// Controlled API fixtures + delayed real Clerk bootstrap make the boot race reproducible.
import { chromium } from '@playwright/test'
import { mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'

const label = process.argv[2] || 'after'
const output = path.resolve('../.release-evidence/first-load', label)
await mkdir(output, { recursive: true })
const browser = await chromium.launch({ headless: true })
try {
  for (const viewport of [{ width: 390, height: 844 }, { width: 1280, height: 800 }]) {
    for (const routePath of ['/', '/events/nope']) {
      const name = `${viewport.width}-${routePath === '/' ? 'home' : '404'}`
      const dir = path.join(output, name)
      await mkdir(dir, { recursive: true })
      const context = await browser.newContext({ viewport, serviceWorkers: 'block' })
      const page = await context.newPage()
      const requests = []
      const errors = []
      page.on('pageerror', error => errors.push(error.message.replace(/pk_(test|live)_\S+/g, '[redacted]')))
      page.on('request', request => {
        const url = new URL(request.url())
        if (url.pathname.startsWith('/api/v1/')) requests.push({ at: Date.now(), method: request.method(), path: url.pathname })
      })
      await page.route('**/api/v1/**', async route => {
        const pathname = new URL(route.request().url()).pathname
        const delay = pathname.endsWith('/health') ? 600 : pathname.endsWith('/config') ? 700 : 1200
        await new Promise(resolve => setTimeout(resolve, delay))
        const status = pathname.endsWith('/events/nope') ? 404 : 200
        const body = pathname.endsWith('/health') ? { status: 'ok' }
          : pathname.endsWith('/config') ? { environment: 'production', payment_mode: 'live', launch_capabilities: {} }
            : pathname.endsWith('/events') ? { events: [] } : {}
        await route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
      })
      // Keep real Clerk auth, but reproduce the reported late resolution after
      // public routes have mounted. No auth response or user data is fabricated.
      await page.route('**/*clerk*', async route => {
        if (route.request().resourceType() === 'script') await new Promise(resolve => setTimeout(resolve, 2200))
        await route.continue()
      })
      await page.addInitScript(() => {
        const audit = window.bootAudit = { firstShellAt: null, replacements: 0, removals: 0, cls: 0, shifts: [], samples: [], clerkLoadedAt: null }
        let shell
        const check = records => {
          if (shell) for (const record of records || []) for (const removed of record.removedNodes) {
            if (removed === shell || removed.contains?.(shell)) audit.removals++
          }
          const latest = document.querySelector('.app-shell')
          if (latest && latest !== shell) {
            if (shell) audit.replacements++
            else audit.firstShellAt = performance.now()
            shell = latest
          }
        }
        new MutationObserver(check).observe(document, { childList: true, subtree: true })
        new PerformanceObserver(list => {
          for (const entry of list.getEntries()) if (!entry.hadRecentInput) {
            audit.cls += entry.value
            audit.shifts.push({ at: entry.startTime, value: entry.value })
          }
        }).observe({ type: 'layout-shift', buffered: true })
        setInterval(() => {
          if (window.Clerk?.loaded && !audit.clerkLoadedAt) audit.clerkLoadedAt = performance.now()
          audit.samples.push({ at: performance.now(), shell: !!document.querySelector('.app-shell'), splash: !!document.querySelector('.boot-splash'),
            preparing: document.body?.innerText.includes('Preparing your account'), heading: document.querySelector('h1')?.textContent,
            loading: document.body?.innerText.includes('Loading upcoming events'), background: document.body && getComputedStyle(document.body).backgroundColor })
        }, 100)
      })
      const cdp = await context.newCDPSession(page)
      await cdp.send('Network.enable')
      await cdp.send('Network.setCacheDisabled', { cacheDisabled: true })
      await cdp.send('Emulation.setCPUThrottlingRate', { rate: 4 })
      const started = Date.now()
      await page.goto(`http://127.0.0.1:5221${routePath}`, { waitUntil: 'commit' })
      const frames = []
      for (let frame = 0; Date.now() - started < 10_000; frame++) {
        const at = Date.now() - started
        const file = `${String(frame).padStart(3, '0')}-${at}ms.png`
        try {
          const screenshot = await cdp.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })
          await writeFile(path.join(dir, file), Buffer.from(screenshot.data, 'base64'))
          frames.push({ at, file })
        } catch (error) {
          // Chromium can reject the very first capture before its first frame.
          frames.push({ at, error: error.message })
        }
        await new Promise(resolve => setTimeout(resolve, Math.max(0, 100 - (Date.now() - started - at))))
      }
      const audit = await page.evaluate(() => ({ ...window.bootAudit, clerkLoaded: !!window.Clerk?.loaded,
        title: document.title, overflow: document.documentElement.scrollWidth > innerWidth,
        socialImages: [...document.querySelectorAll('meta[property="og:image"],meta[name="twitter:image"]')].map(tag => ({ type: tag.getAttribute('property') || tag.name, image: tag.content })) }))
      const result = { label, viewport, routePath, ...audit, frames, requests: requests.map(request => ({ ...request, at: request.at - started })), errors }
      await writeFile(path.join(dir, 'timeline.json'), JSON.stringify(result, null, 2))
      process.stdout.write(JSON.stringify({ label, name, firstShellAt: audit.firstShellAt, replacements: audit.replacements, removals: audit.removals, cls: audit.cls, clerkLoaded: audit.clerkLoaded, clerkLoadedAt: audit.clerkLoadedAt,
        eventsRequests: requests.filter(request => request.path === '/api/v1/events').length, configRequests: requests.filter(request => request.path === '/api/v1/config').length, frames: frames.length, errors }) + '\n')
      await context.close()
    }
  }
} finally { await browser.close() }
