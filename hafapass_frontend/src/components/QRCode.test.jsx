import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { QRCodeSVG } from 'qrcode.react'
import QRCode from './QRCode'

describe('QRCode', () => {
  it('encodes long signed credentials without exposing them in the accessible name', () => {
    const credential = 'signed-ticket-credential-'.repeat(8)
    const { container } = render(<QRCode value={credential} size={220} />)

    const image = screen.getByRole('img', { name: 'Ticket entry QR code' })
    expect(image).toHaveAccessibleName('Ticket entry QR code')
    expect(image.tagName.toLowerCase()).toBe('svg')
    expect(image).toHaveAttribute('width', '220')
    expect(image).toHaveAttribute('height', '220')
    expect(container.querySelectorAll('path').length).toBeGreaterThan(0)

    const reference = render(<QRCodeSVG value={credential} size={220} level="M" marginSize={2} />)
    const encodedPaths = [...image.querySelectorAll('path')].map(path => path.getAttribute('d'))
    const referencePaths = [...reference.container.querySelectorAll('path')].map(path => path.getAttribute('d'))
    expect(encodedPaths).toEqual(referencePaths)
  })
})
