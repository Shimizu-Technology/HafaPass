import { isDarkHeaderPath } from '../src/utils/headerTheme.js'

export function headerThemePlugin() {
  return {
    name: 'hafapass-header-theme',
    transformIndexHtml: {
      order: 'pre',
      handler: html => html.replace('%HEADER_THEME_SCRIPT%', `
        const dark = (${isDarkHeaderPath.toString()})(window.location.pathname)
        const color = dark ? '#032827' : '#ffffff'
        document.querySelector('meta[name="theme-color"]').content = color
        document.documentElement.style.setProperty('--startup-header-color', color)
      `),
    },
  }
}
