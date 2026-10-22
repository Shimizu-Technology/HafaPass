// @vitest-environment node
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import { translateSafely } from '../../scripts/translate-safe-lib.mjs'

const englishYaml = 'emails:\n  hi: "Hi %{name}"\n'

function project() {
  const root = mkdtempSync(join(tmpdir(), 'hp-translate-'))
  mkdirSync(join(root, 'src/locales'), { recursive: true })
  mkdirSync(join(root, 'api'), { recursive: true })
  writeFileSync(join(root, 'gt.config.json'), JSON.stringify({
    defaultLocale: 'en', locales: ['ko'],
    files: { json: { include: ['src/locales/[locale].json'] }, yaml: { include: ['api/[locale].yml'] } },
  }))
  writeFileSync(join(root, 'src/locales/en.json'), JSON.stringify({ greet: 'Hi {{name}}', plain: 'Events' }))
  writeFileSync(join(root, 'src/locales/ko.json'), JSON.stringify({ greet: '안녕 {{name}}', plain: '이벤트' }))
  writeFileSync(join(root, 'api/en.yml'), englishYaml)
  writeFileSync(join(root, 'api/ko.yml'), 'emails:\n  hi: "안녕 %{name}"\n')
  writeFileSync(join(root, 'gt-lock.json'), '{"version":2}')
  return root
}

const env = { GT_API_KEY: 'key', GT_PROJECT_ID: 'project' }
const log = { info: vi.fn(), warn: vi.fn() }
const read = (root, path) => readFileSync(join(root, path), 'utf-8')

describe('translate-safe', () => {
  it('skips without credentials', () => {
    const run = vi.fn()
    expect(translateSafely({ root: project(), env: {}, run, log })).toBe('skipped')
    expect(run).not.toHaveBeenCalled()
  })

  it('keeps valid output and passes a timeout to the CLI', () => {
    const root = project()
    const run = vi.fn(() => writeFileSync(join(root, 'src/locales/ko.json'), JSON.stringify({ greet: '반가워요 {{name}}', plain: '행사' })))
    expect(translateSafely({ root, env, run, log, timeout: 1234 })).toBe('translated')
    expect(run).toHaveBeenCalledWith('npx gt translate', expect.objectContaining({ timeout: 1234, cwd: root }))
    expect(JSON.parse(read(root, 'src/locales/ko.json')).greet).toBe('반가워요 {{name}}')
  })

  it('restores every committed file when output breaks placeholders or JSON', () => {
    const root = project()
    const before = { ko: read(root, 'src/locales/ko.json'), yml: read(root, 'api/ko.yml'), lock: read(root, 'gt-lock.json') }
    const run = vi.fn(() => {
      writeFileSync(join(root, 'src/locales/ko.json'), JSON.stringify({ greet: '안녕 {{nmae}}' }))
      writeFileSync(join(root, 'api/ko.yml'), 'emails:\n  hi: "안녕"\n')
      writeFileSync(join(root, 'gt-lock.json'), '{"version":3}')
    })
    expect(translateSafely({ root, env, run, log })).toBe('restored')
    expect(read(root, 'src/locales/ko.json')).toBe(before.ko)
    expect(read(root, 'api/ko.yml')).toBe(before.yml)
    expect(read(root, 'gt-lock.json')).toBe(before.lock)
    expect(log.warn).toHaveBeenCalledWith(expect.stringContaining('changed its {{placeholders}}'))

    const broken = vi.fn(() => writeFileSync(join(root, 'src/locales/ko.json'), '{ not json'))
    expect(translateSafely({ root, env, run: broken, log })).toBe('restored')
    expect(read(root, 'src/locales/ko.json')).toBe(before.ko)
  })

  it('restores the committed files when the CLI times out or fails, and removes files it created', () => {
    const root = project()
    const before = read(root, 'src/locales/ko.json')
    const run = vi.fn(() => {
      writeFileSync(join(root, 'src/locales/ko.json'), JSON.stringify({ greet: 'partial' }))
      const error = new Error('spawnSync /bin/sh ETIMEDOUT')
      error.code = 'ETIMEDOUT'
      throw error
    })
    expect(translateSafely({ root, env, run, log })).toBe('restored')
    expect(read(root, 'src/locales/ko.json')).toBe(before)

    const fresh = project()
    writeFileSync(join(fresh, 'gt.config.json'), JSON.stringify({ defaultLocale: 'en', locales: ['ko', 'ja'],
      files: { json: { include: ['src/locales/[locale].json'] } } }))
    const created = vi.fn(() => { writeFileSync(join(fresh, 'src/locales/ja.json'), '{}'); throw new Error('fetch failed') })
    expect(translateSafely({ root: fresh, env, run: created, log })).toBe('restored')
    expect(existsSync(join(fresh, 'src/locales/ja.json'))).toBe(false)
  })
})
