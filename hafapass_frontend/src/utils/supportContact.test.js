import { afterEach, describe, expect, it, vi } from 'vitest'
import { supportMailto } from './supportContact'

afterEach(() => vi.unstubAllEnvs())

describe('support contact configuration', () => {
  it('uses the configured operator mailbox and safely encodes order context', () => {
    vi.stubEnv('VITE_SUPPORT_EMAIL', ' support+finance@example.test ')
    const subject = 'Refund review for order HP-A&B / #42?'
    const href = supportMailto(subject)
    expect(href).toBe(`mailto:support%2Bfinance@example.test?subject=${encodeURIComponent(subject)}`)
    expect(new URL(href).searchParams.get('subject')).toBe(subject)
    expect([...new URL(href).searchParams.keys()]).toEqual(['subject'])
  })

  it.each([undefined, '', '   '])('uses the existing public operator inbox when configuration is %s', value => {
    vi.stubEnv('VITE_SUPPORT_EMAIL', value)
    expect(supportMailto()).toBe('mailto:shimizutechnology@gmail.com?subject=HafaPass%20Support')
  })
})
