// Netlify Edge Function: Detect social media crawlers and serve OG meta tags
// from the Rails API instead of the SPA (which crawlers can't render)

const CRAWLER_USER_AGENTS = [
  'facebookexternalhit',
  'Facebot',
  'Twitterbot',
  'LinkedInBot',
  'WhatsApp',
  'TelegramBot',
  'Slackbot',
  'Discordbot',
  'Pinterest',
  'Googlebot',
  'bingbot',
  'iMessageBot',
]

const API_BASE = 'https://hafapass-api.onrender.com'

export default async (request, context) => {
  const url = new URL(request.url)
  const ua = request.headers.get('user-agent') || ''

  // Only intercept /events/:slug paths
  const match = url.pathname.match(/^\/events\/([^/]+)$/)
  if (!match) {
    return context.next()
  }

  // Check if request is from a social media crawler
  const isCrawler = CRAWLER_USER_AGENTS.some(bot =>
    ua.toLowerCase().includes(bot.toLowerCase())
  )

  if (!isCrawler) {
    return context.next()
  }

  // Proxy to Rails OG endpoint
  const slug = match[1]
  try {
    const response = await fetch(`${API_BASE}/og/events/${slug}`)
    return new Response(await response.text(), {
      status: response.status,
      headers: { 'content-type': 'text/html; charset=utf-8' },
    })
  } catch {
    return context.next()
  }
}

export const config = {
  path: '/events/*',
}
