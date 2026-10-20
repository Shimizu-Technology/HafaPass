// Build-time public-site configuration. Every absolute HåfaPass URL in the
// static shell (canonical, Open Graph, JSON-LD, robots.txt) comes from
// VITE_PUBLIC_WEB_URL so moving the site to another domain is a config change.

export const PUBLIC_URL_TOKEN = '%PUBLIC_WEB_URL%'
const BLOCK = /[ \t]*<!-- public-site-url -->[\s\S]*?<!-- \/public-site-url -->\n?/g
const MARKERS = /[ \t]*<!-- \/?public-site-url -->\n?/g

// Returns the http(s) origin of a configured URL, or '' when unset or invalid.
export function normalizeOrigin(value) {
  try {
    const url = new URL(String(value || '').trim())
    return ['https:', 'http:'].includes(url.protocol) ? url.origin : ''
  } catch {
    return ''
  }
}

// With a configured site, absolute tags are filled in. Without one, they are
// removed rather than pointing at a domain HåfaPass may not own; the runtime
// SEO component still sets canonical/OG tags from the browser origin.
export function renderPublicSiteHtml(html, publicWebUrl) {
  const origin = normalizeOrigin(publicWebUrl)
  if (!origin) return html.replace(BLOCK, '')
  return html.replace(MARKERS, '').replaceAll(PUBLIC_URL_TOKEN, origin)
}

export function robotsTxt(publicWebUrl) {
  const origin = normalizeOrigin(publicWebUrl)
  const lines = ['User-agent: *', 'Allow: /', 'Disallow: /dashboard', 'Disallow: /api/']
  if (origin) lines.push('', `Sitemap: ${origin}/sitemap.xml`)
  return `${lines.join('\n')}\n`
}

export function publicSitePlugin(publicWebUrl) {
  return {
    name: 'hafapass-public-site',
    transformIndexHtml: { order: 'pre', handler: html => renderPublicSiteHtml(html, publicWebUrl) },
    configureServer(server) {
      server.middlewares.use('/robots.txt', (_request, response) => {
        response.setHeader('content-type', 'text/plain; charset=utf-8')
        response.end(robotsTxt(publicWebUrl))
      })
    },
    generateBundle() {
      this.emitFile({ type: 'asset', fileName: 'robots.txt', source: robotsTxt(publicWebUrl) })
    },
  }
}
