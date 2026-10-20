import { describe, expect, it } from 'vitest'
import { resolvePublicWebUrl } from './site'

describe('public site URL', () => {
  it('uses the configured public site without a trailing slash', () => {
    expect(resolvePublicWebUrl(' https://tickets.example.test/ ', 'http://localhost:5173')).toBe('https://tickets.example.test')
  })

  it.each([undefined, '', '  '])('falls back to the current origin when configuration is %s', value => {
    expect(resolvePublicWebUrl(value, 'https://preview.example.test')).toBe('https://preview.example.test')
  })

  it('never invents a hardcoded domain', () => {
    expect(resolvePublicWebUrl('', null)).toBe('')
  })
})
