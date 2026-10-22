import { render, waitFor } from '@testing-library/react'
import { HelmetProvider } from 'react-helmet-async'
import { describe, expect, it } from 'vitest'
import SEO from './SEO'
import indexHtml from '../../index.html?raw'

function siteStructuredData() {
  const match = indexHtml.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)
  return JSON.parse(match[1])['@graph']
}

describe('SEO', () => {
  it('keeps private proof pages out of indexes and structured search results', async () => {
    render(
      <HelmetProvider>
        <SEO
          title="Private live-money proof"
          noIndex
          jsonLd={{ '@context': 'https://schema.org', '@type': 'Event' }}
        />
      </HelmetProvider>,
    )

    await waitFor(() => {
      expect(document.head.querySelector('meta[name="robots"]')).toHaveAttribute(
        'content',
        'noindex, nofollow, noarchive',
      )
    })
    expect(document.head.querySelector('script[type="application/ld+json"]')).not.toBeInTheDocument()
  })

  it('names the brand HåfaPass and keeps the plain HafaPass spelling searchable', () => {
    const graph = siteStructuredData()
    for (const type of ['Organization', 'WebSite']) {
      const node = graph.find(item => item['@type'] === type)
      expect(node.name).toBe('HåfaPass')
      expect(node.alternateName).toEqual(['HafaPass', 'Hafa Pass'])
    }
    expect(indexHtml).toContain('<meta property="og:site_name" content="HåfaPass" />')
    expect(indexHtml).toMatch(/<meta name="description" content="HåfaPass \(HafaPass\)/)
  })

  it('uses the HåfaPass name in default titles and the site name', async () => {
    render(
      <HelmetProvider>
        <SEO title="Events" />
      </HelmetProvider>,
    )

    await waitFor(() => expect(document.title).toBe('Events | HåfaPass'))
    expect(document.head.querySelector('meta[property="og:site_name"]')).toHaveAttribute('content', 'HåfaPass')
    expect(document.head.querySelector('meta[name="description"]').getAttribute('content')).toContain('(HafaPass)')
  })
})
