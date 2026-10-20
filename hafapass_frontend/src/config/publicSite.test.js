import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { cwd } from 'node:process'
import { describe, expect, it } from 'vitest'
import { normalizeOrigin, renderPublicSiteHtml, robotsTxt } from '../../config/publicSite.js'

const indexHtml = readFileSync(resolve(cwd(), 'index.html'), 'utf8')

describe('build-time public site URLs', () => {
  it('fills Open Graph images and structured data from VITE_PUBLIC_WEB_URL', () => {
    const html = renderPublicSiteHtml(indexHtml, 'https://tickets.example.test/')

    // Per-page canonical/og:url come from the SEO component; a static copy would conflict.
    expect(html).not.toMatch(/<link rel="canonical"|property="og:url"/)
    expect(html).toContain('<meta property="og:image" content="https://tickets.example.test/icons/icon-512.png" />')
    const jsonLd = JSON.parse(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1])
    expect(jsonLd['@graph'][0]).toEqual(expect.objectContaining({ url: 'https://tickets.example.test', logo: 'https://tickets.example.test/icons/icon-512.png' }))
    expect(html).not.toMatch(/%PUBLIC_WEB_URL%|public-site-url|hafapass\.com/)
  })

  it('omits absolute tags instead of guessing a domain when unset', () => {
    const html = renderPublicSiteHtml(indexHtml, '')
    expect(html).not.toMatch(/%PUBLIC_WEB_URL%|property="og:image"|ld\+json|hafapass\.com/)
    expect(html).toContain('og:title')
    expect(html).toContain('<div id="root"></div>')
  })

  it('points robots.txt at the configured sitemap only', () => {
    expect(robotsTxt('https://tickets.example.test')).toContain('Sitemap: https://tickets.example.test/sitemap.xml')
    expect(robotsTxt('https://tickets.example.test')).toContain('Disallow: /dashboard')
    expect(robotsTxt(undefined)).not.toContain('Sitemap:')
  })

  it('accepts only http(s) origins', () => {
    expect(normalizeOrigin('https://tickets.example.test/path')).toBe('https://tickets.example.test')
    expect(normalizeOrigin('javascript:alert(1)')).toBe('')
  })
})
