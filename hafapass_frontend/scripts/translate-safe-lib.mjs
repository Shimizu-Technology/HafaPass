// Guarded `gt translate` for builds (see translate-safe.mjs and
// docs/TRANSLATIONS.md). The committed translation files are snapshotted
// first; if the CLI fails, times out, or writes anything that does not
// validate against the English source, every file is put back exactly as it
// was, so a build never ships unvalidated translations.
import { execSync } from 'node:child_process'
import { existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

export const TRANSLATE_TIMEOUT_MS = 120_000

const JSON_PLACEHOLDER = /\{\{\s*([\w.]+)\s*\}\}/g
const YAML_PLACEHOLDER = /%\{(\w+)\}/g

const placeholders = (text, pattern) => [...String(text).matchAll(pattern)].map(match => match[1]).sort().join(',')

function flatten(value, prefix = '', out = {}) {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    for (const [key, child] of Object.entries(value)) flatten(child, prefix ? `${prefix}.${key}` : key, out)
  } else out[prefix] = value
  return out
}

// Problems in one generated JSON locale file compared with en.json.
export function jsonProblems(english, translatedText, file) {
  let translated
  try { translated = JSON.parse(translatedText) } catch { return [`${file}: not valid JSON`] }
  const source = flatten(english)
  return Object.entries(flatten(translated)).flatMap(([key, value]) => {
    if (!(key in source)) return []
    if (typeof value !== 'string') return [`${file}: ${key} is not text`]
    return placeholders(value, JSON_PLACEHOLDER) === placeholders(source[key], JSON_PLACEHOLDER) ? []
      : [`${file}: ${key} changed its {{placeholders}}`]
  })
}

// Email YAML is checked as a whole: the same %{placeholders}, the same
// number of times, under the same top-level key. The API also ignores any
// single string whose placeholders differ (config/locales/emails.rb).
const withoutComments = text => String(text).split('\n').filter(line => !line.trimStart().startsWith('#')).join('\n')

export function yamlProblems(englishSource, translatedSource, file) {
  const englishText = withoutComments(englishSource)
  const translatedText = withoutComments(translatedSource)
  const problems = []
  if (!/^emails:\s*$/m.test(translatedText)) problems.push(`${file}: missing the emails: root`)
  if (placeholders(translatedText, YAML_PLACEHOLDER) !== placeholders(englishText, YAML_PLACEHOLDER)) {
    problems.push(`${file}: %{placeholders} differ from en.yml`)
  }
  return problems
}

export function translationTargets(root) {
  const config = JSON.parse(readFileSync(join(root, 'gt.config.json'), 'utf-8'))
  const jsonPattern = config.files?.json?.include?.[0]
  const yamlPattern = config.files?.yaml?.include?.[0]
  const fill = (pattern, locale) => resolve(root, pattern.replace('[locale]', locale))
  return {
    locales: config.locales,
    english: { json: jsonPattern && fill(jsonPattern, config.defaultLocale), yaml: yamlPattern && fill(yamlPattern, config.defaultLocale) },
    files: config.locales.flatMap(locale => [
      jsonPattern && { kind: 'json', path: fill(jsonPattern, locale) },
      yamlPattern && { kind: 'yaml', path: fill(yamlPattern, locale) },
    ].filter(Boolean)).concat({ kind: 'lock', path: join(root, 'gt-lock.json') }),
  }
}

export function snapshot(paths) {
  return new Map(paths.map(path => [path, existsSync(path) ? readFileSync(path) : null]))
}

export function restore(saved) {
  for (const [path, contents] of saved) {
    if (contents === null) rmSync(path, { force: true })
    else writeFileSync(path, contents)
  }
}

export function validate(targets) {
  const englishJson = targets.english.json && JSON.parse(readFileSync(targets.english.json, 'utf-8'))
  const englishYaml = targets.english.yaml && readFileSync(targets.english.yaml, 'utf-8')
  return targets.files.flatMap(({ kind, path }) => {
    if (kind === 'lock') return []
    if (!existsSync(path)) return [`${path}: missing`]
    const text = readFileSync(path, 'utf-8')
    return kind === 'json' ? jsonProblems(englishJson, text, path) : yamlProblems(englishYaml, text, path)
  })
}

// Returns 'skipped', 'translated' or 'restored'; never throws.
export function translateSafely({ root, env = process.env, run = execSync, log = console, timeout = TRANSLATE_TIMEOUT_MS }) {
  if (!env.GT_API_KEY || !env.GT_PROJECT_ID) {
    log.info('GT_API_KEY/GT_PROJECT_ID not set; building with the committed locale files.')
    return 'skipped'
  }
  let targets
  try { targets = translationTargets(root) } catch (error) {
    log.warn(`Translation config unreadable; building with the committed locale files. (${error.message})`)
    return 'skipped'
  }
  const saved = snapshot(targets.files.map(file => file.path))
  try {
    run('npx gt translate', { stdio: 'inherit', cwd: root, timeout, env })
    const problems = validate(targets)
    if (problems.length === 0) return 'translated'
    log.warn(`Translations failed validation; restored the committed files.\n- ${problems.join('\n- ')}`)
  } catch (error) {
    log.warn(`Translation update failed; restored the committed locale files. (${error.message})`)
  }
  restore(saved)
  return 'restored'
}

export function readGtEnv(root, env = process.env) {
  for (const file of ['.env', '.env.local']) {
    const path = resolve(root, file)
    if (!existsSync(path)) continue
    for (const line of readFileSync(path, 'utf-8').split('\n')) {
      const trimmed = line.trim()
      if (!trimmed || trimmed.startsWith('#')) continue
      const eq = trimmed.indexOf('=')
      if (eq === -1) continue
      const key = trimmed.slice(0, eq).trim()
      if (!key.startsWith('GT_')) continue
      let value = trimmed.slice(eq + 1).trim()
      if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1)
      if (!env[key]) env[key] = value
    }
  }
  return env
}

