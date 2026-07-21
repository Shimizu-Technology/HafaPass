import { render, waitFor } from '@testing-library/react'
import { HelmetProvider } from 'react-helmet-async'
import { describe, expect, it } from 'vitest'
import SEO from './SEO'

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
})
