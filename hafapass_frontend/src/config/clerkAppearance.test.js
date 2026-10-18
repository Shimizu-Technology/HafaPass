import { describe, expect, it } from 'vitest'
import tailwindConfig from '../../tailwind.config.js'
import { clerkAppearance } from './clerkAppearance'

describe('Clerk appearance', () => {
  it('uses the HafaPass primary action, text and danger tokens', () => {
    const { colors } = tailwindConfig.theme.extend
    expect(clerkAppearance.variables).toMatchObject({
      colorPrimary: colors.action.DEFAULT,
      colorDanger: colors.action.danger,
      colorText: colors.content.DEFAULT,
      colorTextSecondary: colors.content.muted,
      borderRadius: '0.75rem',
    })
    expect(clerkAppearance.variables.fontFamily).toContain('Plus Jakarta Sans Variable')
  })
})
