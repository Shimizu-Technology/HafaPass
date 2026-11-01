import { isDarkHeaderPath, isDarkPagePath } from '../src/utils/headerTheme.js'

export const STARTUP_COLORS = {
  dark: '#032827', // brand-950
  light: '#ffffff',
  page: '#f8fafb', // surface
  wordmark: '#0b6563', // brand-700
}

export function headerThemePlugin() {
  return {
    name: 'hafapass-header-theme',
    transformIndexHtml: {
      order: 'pre',
      handler: html => html.replace('%HEADER_THEME_SCRIPT%', `
        const path = window.location.pathname
        const dark = (${isDarkHeaderPath.toString()})(path)
        const darkPage = (${isDarkPagePath.toString()})(path)
        const color = dark ? '${STARTUP_COLORS.dark}' : '${STARTUP_COLORS.light}'
        const style = document.documentElement.style
        document.querySelector('meta[name="theme-color"]').content = color
        style.setProperty('--startup-header-color', color)
        style.setProperty('--startup-page-color', darkPage ? '${STARTUP_COLORS.dark}' : '${STARTUP_COLORS.page}')
        style.setProperty('--startup-wordmark-color', darkPage ? '${STARTUP_COLORS.light}' : '${STARTUP_COLORS.wordmark}')
      `),
    },
  }
}
