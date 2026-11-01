import { describe, expect, it } from 'vitest'
import { visibleWallets, walletPlatform } from './walletPlatform'

const iPhone = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1'
const iPad = 'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'
// iPadOS Safari and desktop Safari on a Mac send the same user agent.
const macUserAgent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15'
const android = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36'
const windows = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
const linux = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
const chromebook = 'Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'

describe('wallet platform detection', () => {
  it.each([
    ['iPhone', { userAgent: iPhone, maxTouchPoints: 5 }, 'apple'],
    ['iPad (mobile UA)', { userAgent: iPad, maxTouchPoints: 5 }, 'apple'],
    ['iPadOS (Mac UA, touch screen)', { userAgent: macUserAgent, maxTouchPoints: 5 }, 'apple'],
    ['Mac desktop', { userAgent: macUserAgent, maxTouchPoints: 0 }, 'unknown'],
    ['Mac desktop with one touch point', { userAgent: macUserAgent, maxTouchPoints: 1 }, 'unknown'],
    ['Mac desktop without maxTouchPoints', { userAgent: macUserAgent }, 'unknown'],
    ['Android phone', { userAgent: android, maxTouchPoints: 5 }, 'android'],
    ['Windows desktop', { userAgent: windows, maxTouchPoints: 0 }, 'unknown'],
    ['Windows touch laptop', { userAgent: windows, maxTouchPoints: 10 }, 'unknown'],
    ['Linux desktop', { userAgent: linux }, 'unknown'],
    ['Chromebook', { userAgent: chromebook }, 'unknown'],
    ['jsdom', { userAgent: 'Mozilla/5.0 (darwin) AppleWebKit/537.36 (KHTML, like Gecko) jsdom/26.1.0' }, 'unknown'],
    ['empty', { userAgent: '' }, 'unknown'],
  ])('classifies %s', (_name, nav, platform) => {
    expect(walletPlatform(nav)).toBe(platform)
  })

  it('uses client hints only when the user agent is missing', () => {
    expect(walletPlatform({ userAgent: '', userAgentData: { platform: 'Android' } })).toBe('android')
    expect(walletPlatform({ userAgent: '', userAgentData: { platform: 'iOS' } })).toBe('apple')
    expect(walletPlatform({ userAgent: '', userAgentData: { platform: 'macOS' } })).toBe('unknown')
    expect(walletPlatform({ userAgent: '', userAgentData: { platform: 'Windows' } })).toBe('unknown')
    expect(walletPlatform({ userAgent: windows, userAgentData: { platform: 'Android' } })).toBe('unknown')
  })

  it('shows each wallet only where it works, both when unsure, and none when switched off', () => {
    const both = { apple: true, google: true }
    expect(visibleWallets(both, 'apple')).toEqual({ apple: true, google: false })
    expect(visibleWallets(both, 'android')).toEqual({ apple: false, google: true })
    expect(visibleWallets(both, 'unknown')).toEqual({ apple: true, google: true })
    expect(visibleWallets({ apple: false, google: true }, 'unknown')).toEqual({ apple: false, google: true })
    expect(visibleWallets({ apple: false, google: false }, 'unknown')).toEqual({ apple: false, google: false })
    expect(visibleWallets(undefined, 'apple')).toEqual({ apple: false, google: false })
    expect(visibleWallets({ apple: true, google: false }, 'android')).toEqual({ apple: false, google: false })
  })
})
