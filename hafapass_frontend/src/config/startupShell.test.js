import { afterEach, describe, expect, it } from 'vitest'
import indexHtml from '../../index.html?raw'
import manifest from '../../public/manifest.json'
import { headerThemePlugin } from '../../config/headerTheme.js'
import { fontPreloadTags } from '../../config/fontPreload.js'

function runStartupScript(path) {
  window.history.replaceState(null, '', path)
  document.head.innerHTML = '<meta name="theme-color" content="#ffffff">'
  const html = headerThemePlugin().transformIndexHtml.handler(indexHtml)
  const script = html.match(/<script>\s*\/\/ Match Navbar[\s\S]*?<\/script>/)[0].replace(/<\/?script>/g, '')
  new Function(script)()
  const style = document.documentElement.style
  return {
    meta: document.querySelector('meta[name="theme-color"]').content,
    header: style.getPropertyValue('--startup-header-color'),
    page: style.getPropertyValue('--startup-page-color'),
    wordmark: style.getPropertyValue('--startup-wordmark-color'),
  }
}

describe('pre-React startup shell', () => {
  afterEach(() => { document.documentElement.removeAttribute('style'); window.history.replaceState(null, '', '/') })

  it.each([
    ['/', { meta: '#032827', header: '#032827', page: '#032827', wordmark: '#ffffff' }],
    ['/host', { meta: '#032827', header: '#032827', page: '#032827', wordmark: '#ffffff' }],
    ['/tickets/display-qa', { meta: '#032827', header: '#032827', page: '#032827', wordmark: '#ffffff' }],
    ['/events', { meta: '#032827', header: '#032827', page: '#f8fafb', wordmark: '#0b6563' }],
    ['/dashboard', { meta: '#ffffff', header: '#ffffff', page: '#f8fafb', wordmark: '#0b6563' }],
  ])('paints %s in its first-screen colors before the app loads', (path, colors) => {
    expect(runStartupScript(path)).toEqual(colors)
  })

  it('sizes the splash header for the notch and uses brand colors and the display font', () => {
    expect(indexHtml).toContain('height: calc(65px + env(safe-area-inset-top, 0px))')
    expect(indexHtml).toMatch(/\.boot-splash span \{[^}]*"Space Grotesk Variable"/)
    expect(indexHtml).toContain('<meta name="msapplication-TileColor" content="#032827" />')
    expect(indexHtml).not.toContain('#0e7c7b')
  })

  it('preloads only the Latin variable fonts with CORS mode', () => {
    const tags = fontPreloadTags([
      'assets/plus-jakarta-sans-latin-ext-wght-normal-DmpS2jIq.woff2',
      'assets/plus-jakarta-sans-latin-wght-italic-DnD1KgkH.woff2',
      'assets/plus-jakarta-sans-latin-wght-normal-eXO_dkmS.woff2',
      'assets/space-grotesk-latin-wght-normal-BhU9QXUp.woff2',
      'assets/space-grotesk-vietnamese-wght-normal-D0rl6rjA.woff2',
      'assets/index-E4X8nqag.js',
    ])
    expect(tags.map(tag => tag.attrs.href)).toEqual([
      '/assets/plus-jakarta-sans-latin-wght-normal-eXO_dkmS.woff2',
      '/assets/space-grotesk-latin-wght-normal-BhU9QXUp.woff2',
    ])
    expect(tags[0].attrs).toMatchObject({ rel: 'preload', as: 'font', type: 'font/woff2', crossorigin: '' })
  })
})

describe('web app manifest', () => {
  it('uses brand colors and separate any/maskable icon entries', () => {
    expect(manifest.background_color).toBe('#032827')
    expect(manifest.theme_color).toBe('#032827')
    expect(manifest.icons.every(icon => ['any', 'maskable'].includes(icon.purpose))).toBe(true)
    for (const purpose of ['any', 'maskable']) {
      expect(manifest.icons.filter(icon => icon.purpose === purpose).map(icon => icon.sizes)).toEqual(['192x192', '512x512'])
    }
  })
})
