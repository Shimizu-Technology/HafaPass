// Keep the complete dependency graph for offline entry points, rather than
// guessing hashed filenames or dropping chunks shared with an admin page.
export function offlinePrecache() {
  const retained = new Set()
  return {
    plugin: {
      name: 'offline-precache-dependencies',
      generateBundle(_options, bundle) {
        retained.clear()
        function visit(fileName) {
          if (retained.has(fileName)) return
          retained.add(fileName)
          const chunk = bundle[fileName]
          if (chunk?.type !== 'chunk') return
          chunk.imports.forEach(visit)
          // App's dynamic imports enumerate every page and locale. Only the
          // selected offline routes need their lazy dependencies at install.
          if (!chunk.isEntry) chunk.dynamicImports.forEach(visit)
        }
        Object.values(bundle).filter(chunk => chunk.type === 'chunk' && (
          chunk.isEntry || /\/(?:pages\/(?:purchaseFlow|dashboard\/(?:ScannerPage|BoxOfficePage))|components\/NotFound)\.[jt]sx?$/.test(chunk.facadeModuleId || '')
        )).forEach(chunk => visit(chunk.fileName))
      },
    },
    manifestTransform: async entries => ({
      manifest: entries.filter(entry => !entry.url.endsWith('.js') || retained.has(entry.url)),
      warnings: [],
    }),
  }
}
