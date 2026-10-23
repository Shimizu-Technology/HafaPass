// Netlify Edge Function: social link-preview crawlers can't render the SPA, so
// /events/:slug and /policies/:slug requests from them get the Rails OG page.
// Search engines are deliberately absent: Google and Bing render the SPA, and
// the OG page's script redirect back to the public URL would loop for them.
import { apiOrigin } from '../shared/apiOrigin.js'

export const CRAWLER_USER_AGENTS = [
  'facebookexternalhit',
  'Facebot',
  'Twitterbot',
  'LinkedInBot',
  'WhatsApp',
  'TelegramBot',
  'Slackbot',
  'Discordbot',
  'Pinterest',
  'iMessageBot',
]

export function isPreviewCrawler(userAgent) {
  const ua = String(userAgent || '').toLowerCase()
  return CRAWLER_USER_AGENTS.some(bot => ua.includes(bot.toLowerCase()))
}

// The same URL answers crawlers and people differently, so every response from
// an event page varies on User-Agent and the crawler page is never stored by a
// shared cache that could hand it to a person. The SPA keeps its own cache policy.
async function spa(context) {
  const response = await context.next()
  const varied = new Response(response.body, response)
  varied.headers.append('vary', 'User-Agent')
  return varied
}

export default async (request, context) => {
  const pathname = new URL(request.url).pathname
  if (/^\/events\/[^/]+\/preview\/?$/.test(pathname)) {
    const response = await context.next()
    const privateResponse = new Response(response.body, response)
    privateResponse.headers.set('X-Robots-Tag', 'noindex, nofollow')
    privateResponse.headers.set('Referrer-Policy', 'no-referrer')
    return privateResponse
  }
  const match = pathname.match(/^\/(events|policies)\/([^/]+)\/?$/)
  if (!match) return context.next()
  if (!isPreviewCrawler(request.headers.get('user-agent'))) return spa(context)

  // Without a configured API the crawler simply gets the SPA shell.
  const origin = apiOrigin()
  if (!origin) return spa(context)

  try {
    const response = await fetch(`${origin}/og/${match[1]}/${encodeURIComponent(decodeURIComponent(match[2]))}`)
    // A missing event still gets the API's 404 page; an API outage falls back to the SPA.
    if (!response.ok && response.status !== 404) return spa(context)
    return new Response(await response.text(), {
      status: response.status,
      headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'private, no-store', vary: 'User-Agent' },
    })
  } catch {
    return spa(context)
  }
}

export const config = {
  path: ['/events/*', '/policies/*'],
}
