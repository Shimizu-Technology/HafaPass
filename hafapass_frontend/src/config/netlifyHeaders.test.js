import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { cwd } from 'node:process'
import { describe, expect, it } from 'vitest'

// Netlify reads hafapass_frontend/netlify.toml (root build.base) or, on legacy
// single-pass sites, the repository-root copy. Their headers must match.
function headerRules(path) {
  const lines = readFileSync(path, 'utf8').split('\n')
  return lines.slice(lines.findIndex(line => line.startsWith('[[headers]]')))
    .map(line => line.trim()).filter(line => line && !line.startsWith('#'))
}

function rules(lines) {
  const parsed = []
  for (const line of lines) {
    if (line === '[[headers]]') parsed.push({ values: {} })
    else if (line.startsWith('for = ')) parsed.at(-1).for = JSON.parse(line.slice(6))
    else if (line !== '[headers.values]') {
      const [key, ...value] = line.split(' = ')
      parsed.at(-1).values[key] = value.join(' = ').slice(1, -1)
    }
  }
  return parsed
}

const frontend = headerRules(resolve(cwd(), 'netlify.toml'))
const root = headerRules(resolve(cwd(), '..', 'netlify.toml'))
const byPath = Object.fromEntries(rules(frontend).map(rule => [rule.for, rule.values]))

describe('Netlify response headers', () => {
  it('keeps the repository-root and frontend header rules identical', () => {
    expect(root).toEqual(frontend)
  })

  it('caches fingerprinted assets for a year and lets Stripe Elements load the fonts', () => {
    expect(byPath['/assets/*']).toEqual({
      'Cache-Control': 'public, max-age=31536000, immutable',
      'Access-Control-Allow-Origin': 'https://js.stripe.com',
    })
  })

  it('keeps credential-bearing pages out of search and never sends their URL as a referrer', () => {
    for (const path of ['/tickets/*', '/orders/*', '/ticket-transfers/*', '/unsubscribe/*', '/organization-invitations/*',
      '/platform-invitations/*', '/events/*/preview']) {
      expect(byPath[path], path).toEqual({ 'X-Robots-Tag': 'noindex, nofollow', 'Referrer-Policy': 'no-referrer' })
    }
  })

  it('keeps sign-in, checkout, account and staff pages out of search without stripping the referrer', () => {
    // Clerk's Turnstile challenge and Stripe 3-D Secure frames may rely on the referring origin.
    for (const path of ['/checkout/*', '/my-tickets', '/saved', '/admin', '/admin/*', '/support', '/support/*', '/privacy',
      '/privacy/*', '/account/*', '/sign-in', '/sign-in/*', '/sign-up', '/sign-up/*', '/dashboard', '/dashboard/*']) {
      expect(byPath[path], path).toEqual({ 'X-Robots-Tag': 'noindex, nofollow' })
    }
    expect(byPath['/*']['Referrer-Policy']).toBe('strict-origin-when-cross-origin')
  })

  it('reports, without enforcing, a content security policy for the services the app uses', () => {
    const policy = byPath['/*']['Content-Security-Policy-Report-Only']
    expect(byPath['/*']['Content-Security-Policy']).toBe("frame-ancestors 'none'")
    for (const source of ['https://js.stripe.com', 'https://api.stripe.com', 'https://hooks.stripe.com', 'https://*.clerk.accounts.dev',
      'https://img.clerk.com', 'https://cdn.protect.clerk.com', 'https://*.client.protect.clerk.com:*', 'https://*.sentry.io', 'https://hafapass-api.onrender.com', '.s3.ap-southeast-2.amazonaws.com']) {
      expect(policy).toContain(source)
    }
    expect(policy).not.toMatch(/fonts\.googleapis|fonts\.gstatic/)
  })
})
