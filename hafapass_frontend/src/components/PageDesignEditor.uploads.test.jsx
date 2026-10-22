import { useState } from 'react'
import { act, fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import PageDesignEditor from './PageDesignEditor'

const pending = []
vi.mock('./CoverImageUpload', () => ({ default: ({ label = 'Cover image', onUploaded }) => (
  <button type="button" onClick={() => new Promise(resolve => { pending.push(resolve) }).then(onUploaded)}>
    Start {label} upload
  </button>
) }))

function Editor({ initial }) {
  const [design, setDesign] = useState(initial)
  return <>
    <PageDesignEditor event={{ title: 'Reef Night', image_asset_host: 'storage.invalid', ticket_types: [] }}
      design={design} onChange={setDesign} description="" coverUrl="" eventId={7} />
    <output data-testid="design-state">{JSON.stringify(design)}</output>
  </>
}

describe('page design uploads', () => {
  it('preserves alt text and accent edits made while a gallery upload is pending', async () => {
    pending.length = 0
    render(<Editor initial={{ gallery: [{ url: 'https://storage.invalid/uploads/first.webp', alt: 'Original' }],
      sections: [{ type: 'gallery', enabled: true, items: [] }] }} />)
    fireEvent.click(screen.getByRole('button', { name: 'Start Gallery photo upload' }))
    fireEvent.change(screen.getByLabelText('Alt text (required)'), { target: { value: 'Updated stage' } })
    fireEvent.change(screen.getByLabelText('Custom accent hex'), { target: { value: '#123456' } })
    await act(async () => pending.shift()('https://storage.invalid/uploads/second.webp'))
    const design = JSON.parse(screen.getByTestId('design-state').textContent)
    expect(design.accent).toBe('#123456')
    expect(design.gallery).toEqual([
      { url: 'https://storage.invalid/uploads/first.webp', alt: 'Updated stage' },
      { url: 'https://storage.invalid/uploads/second.webp', alt: '' },
    ])
  })

  it('keeps both concurrent image uploads after a section reorder', async () => {
    pending.length = 0
    render(<Editor initial={{ sections: [
      { type: 'lineup', enabled: true, items: [{ name: 'Mia' }] },
      { type: 'sponsors', enabled: true, items: [{ name: 'Partner', logo_url: '' }] },
    ] }} />)
    fireEvent.click(screen.getByRole('button', { name: 'Start Performer photo upload' }))
    fireEvent.click(screen.getByRole('button', { name: 'Start Sponsor logo upload' }))
    fireEvent.click(screen.getByRole('button', { name: 'Move Sponsors / partners up' }))
    await act(async () => pending.pop()('https://storage.invalid/uploads/sponsor.webp'))
    await act(async () => pending.pop()('https://storage.invalid/uploads/performer.webp'))
    const sections = JSON.parse(screen.getByTestId('design-state').textContent).sections
    expect(sections[0].type).toBe('sponsors')
    expect(sections.find(section => section.type === 'sponsors').items[0].logo_url).toBe('https://storage.invalid/uploads/sponsor.webp')
    expect(sections.find(section => section.type === 'lineup').items[0].photo_url).toBe('https://storage.invalid/uploads/performer.webp')
  })
})
