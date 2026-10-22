import { afterEach, describe, expect, it, vi } from 'vitest'
import ogRedirect, { isPreviewCrawler } from '../../netlify/edge-functions/og-redirect.js'
import sitemap from '../../netlify/edge-functions/sitemap.js'
import { apiOrigin } from '../../netlify/shared/apiOrigin.js'

const env = value => ({ get: key => (key === 'HAFAPASS_API_ORIGIN' ? value : undefined) })
const SPA_HTML = '<div id="root"></div>'
const spaResponse = () => new Response(SPA_HTML, { headers: { 'content-type': 'text/html', 'cache-control': 'public, max-age=0, must-revalidate' } })
const context = () => ({ next: vi.fn(async () => spaResponse()) })
const isSpa = async response => (await response.text()) === SPA_HTML
const crawl = (path, ua = 'facebookexternalhit/1.1') => new Request(`https://tickets.example.test${path}`, { headers: { 'user-agent': ua } })

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('edge function API origin', () => {
  it('reads and normalizes HAFAPASS_API_ORIGIN', () => {
    expect(apiOrigin(env(' https://api.example.test/ '))).toBe('https://api.example.test')
    expect(apiOrigin(env('https://api.example.test/api/v1'))).toBe('https://api.example.test')
  })

  it.each([undefined, '', 'not a url', 'ftp://api.example.test'])('is unset for %s', value => {
    expect(apiOrigin(env(value))).toBeNull()
  })
})

describe('share preview edge function', () => {
  it('serves the API OG page to social preview crawlers', async () => {
    vi.stubGlobal('Netlify', { env: env('https://api.example.test') })
    const fetchMock = vi.fn(async () => new Response('<meta property="og:title">', { status: 200 }))
    vi.stubGlobal('fetch', fetchMock)

    const response = await ogRedirect(crawl('/events/beach-party'), context())

    expect(fetchMock).toHaveBeenCalledWith('https://api.example.test/og/events/beach-party')
    expect(response.status).toBe(200)
    expect(response.headers.get('content-type')).toContain('text/html')
    expect(response.headers.get('cache-control')).toBe('private, no-store')
    expect(response.headers.get('vary')).toBe('User-Agent')
    expect(await response.text()).toContain('og:title')
  })

  it('serves policy-specific previews to social crawlers', async () => {
    vi.stubGlobal('Netlify', { env: env('https://api.example.test') })
    const fetchMock = vi.fn(async () => new Response('<meta property="og:title" content="Organizer Agreement">', { status: 200 }))
    vi.stubGlobal('fetch', fetchMock)

    const response = await ogRedirect(crawl('/policies/organizer-agreement'), context())

    expect(fetchMock).toHaveBeenCalledWith('https://api.example.test/og/policies/organizer-agreement')
    expect(response.headers.get('vary')).toBe('User-Agent')
    expect(await response.text()).toContain('Organizer Agreement')
  })

  it('passes through to the SPA when the API origin is not configured', async () => {
    vi.stubGlobal('Netlify', { env: env(undefined) })
    vi.stubGlobal('fetch', vi.fn())
    const ctx = context()

    expect(await isSpa(await ogRedirect(crawl('/events/beach-party'), ctx))).toBe(true)
    expect(fetch).not.toHaveBeenCalled()
  })

  it('leaves people, search engines and other paths on the SPA', async () => {
    vi.stubGlobal('Netlify', { env: env('https://api.example.test') })
    vi.stubGlobal('fetch', vi.fn())
    for (const request of [
      crawl('/events/beach-party', 'Mozilla/5.0 (iPhone)'),
      crawl('/events/beach-party', 'Mozilla/5.0 (compatible; Googlebot/2.1)'),
      crawl('/events/beach-party', 'Mozilla/5.0 (compatible; bingbot/2.0)'),
      crawl('/events'),
      crawl('/events/beach-party/checkout'),
      crawl('/policies/organizer-agreement', 'Mozilla/5.0 (iPhone)'),
    ]) {
      expect(await isSpa(await ogRedirect(request, context()))).toBe(true)
    }
    expect(fetch).not.toHaveBeenCalled()
  })

  it('keeps the existing social crawlers', () => {
    for (const ua of ['facebookexternalhit/1.1', 'Twitterbot/1.0', 'LinkedInBot', 'WhatsApp/2.23', 'TelegramBot', 'Slackbot-LinkExpanding', 'Discordbot/2.0', 'Pinterest/0.2', 'iMessageBot']) {
      expect(isPreviewCrawler(ua)).toBe(true)
    }
  })

  it('falls back to the SPA when the API is down', async () => {
    vi.stubGlobal('Netlify', { env: env('https://api.example.test') })
    vi.stubGlobal('fetch', vi.fn(async () => new Response('down', { status: 503 })))
    expect(await isSpa(await ogRedirect(crawl('/events/beach-party'), context()))).toBe(true)
  })

  it('marks the human event page as varying by User-Agent and keeps the SPA cache policy', async () => {
    vi.stubGlobal('Netlify', { env: env('https://api.example.test') })
    const response = await ogRedirect(crawl('/events/beach-party', 'Mozilla/5.0 (iPhone)'), context())
    expect(response.headers.get('vary')).toBe('User-Agent')
    expect(response.headers.get('cache-control')).toBe('public, max-age=0, must-revalidate')
    expect(await isSpa(response)).toBe(true)
  })
})

describe('sitemap edge function', () => {
  it('proxies the API sitemap from the configured origin', async () => {
    vi.stubGlobal('Netlify', { env: env('https://api.example.test') })
    vi.stubGlobal('fetch', vi.fn(async () => new Response('<urlset/>', { status: 200 })))

    const response = await sitemap(new Request('https://tickets.example.test/sitemap.xml'))

    expect(fetch).toHaveBeenCalledWith('https://api.example.test/sitemap.xml', expect.any(Object))
    expect(response.headers.get('content-type')).toContain('application/xml')
    expect(await response.text()).toBe('<urlset/>')
  })

  it('never answers with the SPA shell when unconfigured or unavailable', async () => {
    vi.stubGlobal('Netlify', { env: env(undefined) })
    expect((await sitemap(new Request('https://tickets.example.test/sitemap.xml'))).status).toBe(404)

    vi.stubGlobal('Netlify', { env: env('https://api.example.test') })
    vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('offline') }))
    expect((await sitemap(new Request('https://tickets.example.test/sitemap.xml'))).status).toBe(502)
  })
})
