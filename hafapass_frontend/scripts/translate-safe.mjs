// Runs `gt translate` before a build when General Translation credentials are
// present (GT_API_KEY and GT_PROJECT_ID, from the environment or an
// untracked .env/.env.local here). Without them, or if the service fails, the
// build continues with the committed locale files. See docs/TRANSLATIONS.md.
import { execSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')

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
    if (!process.env[key]) process.env[key] = value
  }
}

if (process.env.GT_API_KEY && process.env.GT_PROJECT_ID) {
  try {
    execSync('npx gt translate', { stdio: 'inherit', cwd: root })
  } catch (error) {
    console.warn(`\nTranslation update failed; building with the committed locale files. (${error.message})`)
  }
} else {
  console.info('GT_API_KEY/GT_PROJECT_ID not set; building with the committed locale files.')
}
