import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import QRCode from './QRCode'

describe('QRCode', () => {
  it('renders long signed ticket credentials as a real SVG QR code', () => {
    const credential = 'signed-ticket-credential-'.repeat(8)
    const { container } = render(<QRCode value={credential} size={220} />)

    const image = screen.getByRole('img', { name: `QR code for ${credential}` })
    expect(image.tagName.toLowerCase()).toBe('svg')
    expect(image).toHaveAttribute('width', '220')
    expect(container.querySelectorAll('path').length).toBeGreaterThan(0)
  })
})
