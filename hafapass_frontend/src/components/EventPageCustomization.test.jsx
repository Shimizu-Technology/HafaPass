import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import EventDescription from './EventDescription'
import EventPageSections from './EventPageSections'
import PageDesignEditor from './PageDesignEditor'
import { ACCENT_PRESETS, accentStyle, defaultDesign, videoEmbed, normalizePageCustomization, approvedImageUrl } from '../utils/eventPageDesign'

vi.mock('./CoverImageUpload', () => ({ default: () => <div>Image upload</div> }))

const photo = { url: 'https://storage.invalid/uploads/stage.webp', alt: 'Dancers on stage', caption: 'Opening night' }

describe('event page customization', () => {
  it('normalizes malformed and partial designs and rejects off-host images', () => {
    for (const value of [null, 'broken', { sections: {} }, { sections: [{ type: 'faq', enabled: true, items: {} }] }]) {
      const normalized = normalizePageCustomization(value)
      expect(normalized.sections).toHaveLength(7)
      expect(normalized.sections.find(section => section.type === 'faq').items).toEqual([])
    }
    expect(normalizePageCustomization({ sections: [{ type: 'faq', enabled: true, items: [] }] })
      .sections.map(section => section.type)).toContain('gallery')
    expect(approvedImageUrl('https://storage.invalid/uploads/photo.webp', 'storage.invalid')).toBe(true)
    expect(approvedImageUrl('https://storage.invalid.evil.test/uploads/photo.webp', 'storage.invalid')).toBe(false)
    expect(approvedImageUrl('https://evil.test/pixel.webp', 'storage.invalid')).toBe(false)
  })

  it('keeps video click to load and restricts the iframe permissions', () => {
    render(<EventPageSections design={{ sections: [{ type: 'video', enabled: true,
      url: 'https://www.youtube.com/watch?v=abcdefghijk' }] }} />)
    expect(screen.queryByTitle('Event video')).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Play video' }))
    expect(screen.getByTitle('Event video')).toHaveAttribute('sandbox',
      'allow-scripts allow-same-origin allow-presentation allow-popups')
    expect(screen.getByTitle('Event video')).toHaveAttribute('allow',
      'autoplay; encrypted-media; picture-in-picture; fullscreen')
  })

  it('makes missing sections editable when only FAQ was saved', () => {
    let latest = { sections: [{ type: 'faq', enabled: true, items: [] }] }
    const onChange = vi.fn(value => { latest = value; rerender(view()) })
    const view = () => <PageDesignEditor event={{ title: 'Reef Night', ticket_types: [] }} design={latest}
      onChange={onChange} description="" coverUrl="" eventId={7} />
    const { rerender } = render(view())
    fireEvent.click(screen.getByLabelText('Photo gallery'))
    expect(latest.sections.find(section => section.type === 'gallery').enabled).toBe(true)
  })

  it('omits a cleared optional link from the design sent by the editor', () => {
    let latest = { sections: [{ type: 'lineup', enabled: true,
      items: [{ name: 'Mia', url: 'https://example.test' }] }] }
    const onChange = vi.fn(value => { latest = value; rerender(view()) })
    const view = () => <PageDesignEditor event={{ title: 'Reef Night', ticket_types: [] }} design={latest}
      onChange={onChange} description="" coverUrl="" eventId={7} />
    const { rerender } = render(view())
    fireEvent.change(screen.getByLabelText('Link (optional)'), { target: { value: '' } })
    expect(latest.sections.find(section => section.type === 'lineup').items[0]).toEqual({ name: 'Mia' })
  })

  it('hides legacy off-host gallery, lineup, and sponsor images', () => {
    render(<EventPageSections imageAssetHost="storage.invalid" design={{
      gallery: [{ url: 'https://evil.test/pixel.webp', alt: 'Unsafe' }],
      sections: [{ type: 'gallery', enabled: true, items: [] },
        { type: 'lineup', enabled: true, items: [{ name: 'Mia', photo_url: 'https://evil.test/pixel.webp' }] },
        { type: 'sponsors', enabled: true, items: [{ name: 'Partner', logo_url: 'https://evil.test/pixel.webp' }] }]
    }} />)
    expect(screen.getByText('Mia')).toBeInTheDocument()
    expect(screen.getByText('Partner')).toBeInTheDocument()
    expect(document.querySelector('img')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Open photo 1' })).not.toBeInTheDocument()
  })
  it('preserves plain text and renders safe markdown without executable HTML or links', () => {
    const { rerender } = render(<EventDescription text={'First line\n<script>alert(1)</script>'} />)
    expect(screen.getByText(/First line/)).toHaveClass('whitespace-pre-wrap')
    rerender(<EventDescription format="markdown" text={'## Welcome\n**Bold** and [safe](https://example.invalid) [bad](javascript:alert)\n- Item\n<script>alert(1)</script>'} />)
    expect(screen.getByRole('heading', { name: 'Welcome' })).toBeInTheDocument()
    expect(screen.getByText('Bold')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'safe' })).toHaveAttribute('rel', 'noopener noreferrer nofollow')
    expect(screen.queryByRole('link', { name: 'bad' })).not.toBeInTheDocument()
    expect(document.querySelector('script')).toBeNull()
  })

  it('protects contrast for light and dark accents and allowlists video hosts', () => {
    expect(accentStyle('#ffffff')['--event-on-accent']).toBe('#000000')
    expect(accentStyle('#000000')['--event-on-accent']).toBe('#ffffff')
    expect(accentStyle('#ffffff')['--event-link']).not.toBe('#ffffff')
    expect(accentStyle('url(evil)')).toBeUndefined()
    expect(videoEmbed('https://www.youtube.com/watch?v=abcdefghijk')).toContain('youtube-nocookie.com')
    expect(videoEmbed('https://youtube.com.evil.invalid/watch?v=abcdefghijk')).toBeNull()
    const lightness = color => [1, 3, 5].map(index => parseInt(color.slice(index, index + 2), 16) / 255)
      .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4)
      .reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0)
    const ratio = (a, b) => (Math.max(lightness(a), lightness(b)) + 0.05) / (Math.min(lightness(a), lightness(b)) + 0.05)
    for (const accent of [...ACCENT_PRESETS, '#ffffff', '#777777', '#bada55']) {
      const style = accentStyle(accent)
      expect(ratio(accent, style['--event-on-accent'])).toBeGreaterThanOrEqual(4.5)
      expect(ratio('#ffffff', style['--event-link'])).toBeGreaterThanOrEqual(4.5)
    }
  })

  it('renders ordered sections and supports gallery keyboard and Escape', () => {
    const design = { gallery: [photo, { ...photo, url: 'https://storage.invalid/uploads/second.webp', alt: 'Crowd' }], sections: [
      { type: 'faq', enabled: true, items: [{ question: 'When?', answer: 'Tonight' }] },
      { type: 'gallery', enabled: true, items: [] },
      { type: 'lineup', enabled: false, items: [{ name: 'Hidden' }] }
    ] }
    render(<EventPageSections design={design} imageAssetHost="storage.invalid" />)
    expect(screen.getByText('FAQ').compareDocumentPosition(screen.getByText('Photos')) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(screen.queryByText('Hidden')).not.toBeInTheDocument()
    const opener = screen.getByRole('button', { name: 'Open photo 1' })
    fireEvent.click(opener)
    expect(screen.getByRole('dialog')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Close photo' })).toHaveFocus()
    fireEvent.keyDown(document, { key: 'Tab', shiftKey: true })
    expect(screen.getByRole('button', { name: 'Next photo' })).toHaveFocus()
    fireEvent.keyDown(document, { key: 'ArrowRight' })
    expect(screen.getByRole('dialog').querySelector('img')).toHaveAttribute('alt', 'Crowd')
    fireEvent.touchStart(screen.getByRole('dialog'), { touches: [{ clientX: 300 }] })
    fireEvent.touchEnd(screen.getByRole('dialog'), { changedTouches: [{ clientX: 100 }] })
    expect(screen.getByRole('dialog').querySelector('img')).toHaveAttribute('alt', 'Dancers on stage')
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(opener).toHaveFocus()
  })

  it('reorders and toggles sections and updates the preview immediately', () => {
    let latest = { ...defaultDesign(), accent: '#ffffff' }
    const onChange = vi.fn(value => { latest = value; rerender(view()) })
    const view = () => <PageDesignEditor event={{ title: 'Reef Night', ticket_types: [] }} design={latest} onChange={onChange} description="Hello" onDescriptionChange={vi.fn()} coverUrl="" eventId={7} />
    const { rerender } = render(view())
    fireEvent.click(screen.getByRole('button', { name: 'Move Schedule up' }))
    expect(latest.sections[0].type).toBe('schedule')
    fireEvent.click(screen.getByLabelText('Schedule'))
    expect(latest.sections[0].enabled).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: 'Show preview' }))
    fireEvent.click(screen.getByRole('button', { name: 'Desktop' }))
    expect(screen.getByText('Reef Night')).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText('Custom accent hex'), { target: { value: '#123456' } })
    expect(latest.accent).toBe('#123456')
  })
})
