import { describe, expect, it } from 'vitest'
import config from '../../../tailwind.config'

const colors = config.theme.extend.colors
const luminance = hex => {
  const rgb = hex.slice(1).match(/../g).map(value => parseInt(value, 16) / 255)
    .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4)
  return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
}
const ratio = (a, b) => {
  const pair = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (pair[0] + 0.05) / (pair[1] + 0.05)
}

describe('semantic accessible color pairs', () => {
  for (const [role, background] of Object.entries(colors.action)) {
    it(`keeps normal white text readable on the ${role} action`, () => {
      expect(ratio(colors.content.inverse, background)).toBeGreaterThanOrEqual(4.5)
    })
  }
  it('keeps payment help text readable on white', () => {
    expect(ratio(colors.content.muted, colors.surface.raised)).toBeGreaterThanOrEqual(4.5)
  })
  it('keeps secondary footer text readable on the footer surface', () => {
    expect(ratio(colors.content['inverse-muted'], colors.brand[950])).toBeGreaterThanOrEqual(4.5)
  })
  it('keeps the focus indicator distinct from white', () => {
    expect(ratio(colors.focus, colors.surface.raised)).toBeGreaterThanOrEqual(3)
  })
})
