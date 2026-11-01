// Preload the two Latin variable fonts the first screen always uses, so text
// does not swap from the system font after the stylesheet arrives. Other
// subsets (Latin Extended, Vietnamese, italic) still load on demand.
export const PRELOADED_FONTS = [
  /^plus-jakarta-sans-latin-wght-normal-[\w-]+\.woff2$/,
  /^space-grotesk-latin-wght-normal-[\w-]+\.woff2$/,
]

export function fontPreloadTags(fileNames, base = '/') {
  return PRELOADED_FONTS.map(pattern => fileNames.find(fileName => pattern.test(fileName.split('/').pop())))
    .filter(Boolean)
    .map(fileName => ({
      tag: 'link',
      attrs: { rel: 'preload', as: 'font', type: 'font/woff2', href: `${base}${fileName}`, crossorigin: '' },
      injectTo: 'head',
    }))
}

export function fontPreloadPlugin() {
  let base = '/'
  return {
    name: 'hafapass-font-preload',
    apply: 'build',
    configResolved(config) { base = config.base },
    transformIndexHtml: {
      order: 'post',
      handler: (_html, context) => fontPreloadTags(Object.keys(context.bundle || {}), base),
    },
  }
}
