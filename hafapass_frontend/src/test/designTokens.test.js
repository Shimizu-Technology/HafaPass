import { readdirSync, readFileSync } from 'node:fs'
import { join, relative, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

const src = resolve(import.meta.dirname, '..')
const sourceFiles = dir => readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
  const path = join(dir, entry.name)
  if (entry.isDirectory()) return sourceFiles(path)
  return /\.(jsx?|css)$/.test(entry.name) ? [path] : []
})

describe('design tokens', () => {
  // Warm stone greys sat beside the cool neutral scale and read as two greys.
  // Page backgrounds use `surface`; borders and fills use `neutral`.
  it('keeps stone greys out of the interface', () => {
    const offenders = sourceFiles(src)
      .filter(file => file !== import.meta.filename)
      .flatMap(file => readFileSync(file, 'utf8').split('\n')
        .map((line, index) => line.includes('-stone-') ? `${relative(src, file)}:${index + 1}` : null)
        .filter(Boolean))
    expect(offenders).toEqual([])
  })
})
