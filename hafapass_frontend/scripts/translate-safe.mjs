// Runs `gt translate` before a build when General Translation credentials are
// present (GT_API_KEY and GT_PROJECT_ID, from the environment or an
// untracked .env/.env.local here), with a timeout and validation. Without
// credentials, or on any failure, the build continues with the committed
// locale files. See docs/TRANSLATIONS.md.
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { readGtEnv, translateSafely } from './translate-safe-lib.mjs'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
translateSafely({ root, env: readGtEnv(root) })
