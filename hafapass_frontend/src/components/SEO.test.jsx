import { render, waitFor } from '@testing-library/react'
import { HelmetProvider } from 'react-helmet-async'
import { MemoryRouter } from 'react-router-dom'
import { describe, expect, it } from 'vitest'
import SEO from './SEO'
import indexHtml from '../../index.html?raw'
import { PUBLIC_WEB_URL } from '../utils/site'

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
    expect(indexHtml).toContain('<meta name="description" content="Discover events on Guam, buy tickets, and check in with your phone."')
  })

  it('uses the HåfaPass name in default titles and the site name', async () => {
    render(
      <HelmetProvider>
        <SEO title="Events" />
      </HelmetProvider>,
    )

    await waitFor(() => expect(document.title).toBe('Events | HåfaPass'))
    expect(document.head.querySelector('meta[property="og:site_name"]')).toHaveAttribute('content', 'HåfaPass')
    expect(document.head.querySelector('meta[name="description"]').getAttribute('content')).toBe('Discover events on Guam, buy tickets, and check in with your phone.')
  })

  it('keeps private preview pages out of social cards and indexes', async () => {
    render(<HelmetProvider><SEO title="Private preview" noIndex noSocial url="https://example.test/events/private" /></HelmetProvider>)
    await waitFor(() => expect(document.title).toBe('Private preview | HåfaPass'))
    expect(document.head.querySelector('meta[name="robots"]')).toHaveAttribute('content', 'noindex, nofollow, noarchive')
    expect(document.head.querySelector('meta[property^="og:"]')).not.toBeInTheDocument()
    expect(document.head.querySelector('meta[name^="twitter:"]')).not.toBeInTheDocument()
    expect(document.head.querySelector('link[rel="canonical"]')).not.toBeInTheDocument()
  })

  it('adopts the static social images instead of adding duplicate tags', async () => {
    for (const markup of indexHtml.matchAll(/<meta (?:property="og:image(?:[^"]*)?"|name="twitter:image")[^>]+>/g)) {
      const template = document.createElement('template')
      template.innerHTML = markup[0]
      document.head.append(template.content.firstChild)
    }
    const { rerender } = render(<HelmetProvider><SEO /></HelmetProvider>)
    await waitFor(() => {
      expect(document.head.querySelectorAll('meta[property="og:image"]')).toHaveLength(1)
      expect(document.head.querySelectorAll('meta[name="twitter:image"]')).toHaveLength(1)
      expect(document.head.querySelector('meta[property="og:image"]').content).toMatch(/\/og-default\.jpg$/)
    })
    expect(document.head.querySelector('meta[property="og:image:width"]').content).toBe('1200')
    expect(document.head.querySelector('meta[property="og:image:height"]').content).toBe('630')
    rerender(<HelmetProvider><SEO noSocial /></HelmetProvider>)
    await waitFor(() => expect(document.head.querySelectorAll('meta[property^="og:image"],meta[name="twitter:image"]')).toHaveLength(0))
  })

  it('points the canonical URL at the current page instead of the home page', async () => {
    render(<HelmetProvider><MemoryRouter initialEntries={['/venues/hall?sort=soon']}><SEO title="Hall" /></MemoryRouter></HelmetProvider>)
    await waitFor(() => expect(document.head.querySelector('link[rel="canonical"]')).toHaveAttribute('href', `${PUBLIC_WEB_URL}/venues/hall`))
    expect(document.head.querySelector('meta[property="og:url"]')).toHaveAttribute('content', `${PUBLIC_WEB_URL}/venues/hall`)
  })

  it('keeps the home page canonical at the site root and honors an explicit URL', async () => {
    const { rerender } = render(<HelmetProvider><MemoryRouter initialEntries={['/']}><SEO /></MemoryRouter></HelmetProvider>)
    await waitFor(() => expect(document.head.querySelector('link[rel="canonical"]')).toHaveAttribute('href', PUBLIC_WEB_URL))
    rerender(<HelmetProvider><MemoryRouter initialEntries={['/']}><SEO url="https://example.test/events/night" /></MemoryRouter></HelmetProvider>)
    await waitFor(() => expect(document.head.querySelector('link[rel="canonical"]')).toHaveAttribute('href', 'https://example.test/events/night'))
  })

  it('publishes no canonical or og:url for pages kept out of indexes', async () => {
    render(<HelmetProvider><MemoryRouter initialEntries={['/tickets/secret-credential']}><SEO title="Your ticket" noIndex /></MemoryRouter></HelmetProvider>)
    await waitFor(() => expect(document.title).toBe('Your ticket | HåfaPass'))
    expect(document.head.querySelector('link[rel="canonical"]')).not.toBeInTheDocument()
    expect(document.head.querySelector('meta[property="og:url"]')).not.toBeInTheDocument()
    expect(document.head.innerHTML).not.toContain('secret-credential')
  })
})
