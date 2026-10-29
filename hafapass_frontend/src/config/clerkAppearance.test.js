import { describe, expect, it } from 'vitest'
import tailwindConfig from '../../tailwind.config.js'
import { clerkAppearance, clerkLocalization } from './clerkAppearance'

describe('Clerk appearance', () => {
  it('uses the HafaPass primary action, text and danger tokens', () => {
    const { colors } = tailwindConfig.theme.extend
    expect(clerkAppearance.variables).toMatchObject({
      colorPrimary: colors.action.DEFAULT,
      colorDanger: colors.action.danger,
      colorForeground: colors.content.DEFAULT,
      colorMutedForeground: colors.content.muted,
      borderRadius: '0.75rem',
    })
    expect(clerkAppearance.variables.fontFamily).toContain('Plus Jakarta Sans Variable')
  })
})

it('brands the standard and combined Clerk screens while preserving partial defaults', () => {
  for (const [flow, title] of [['signIn', 'Sign in to HåfaPass'], ['signUp', 'Create your HåfaPass account']]) {
    expect(clerkLocalization[flow].start.title).toBe(title)
    expect(clerkLocalization[flow].start.titleCombined).toBe(title)
    expect(clerkLocalization[flow].start.subtitleCombined).toBe(clerkLocalization[flow].start.subtitle)
  }
  expect(clerkLocalization.signUp.start.subtitle).toContain("You don't need an account to buy tickets.")
  expect(clerkAppearance.elements.footerActionLink).not.toContain('inline-flex')
  expect(clerkAppearance.elements.footerActionLink).toContain('min-h-11')
  expect(clerkAppearance.elements).not.toHaveProperty('footer', 'hidden')
})
