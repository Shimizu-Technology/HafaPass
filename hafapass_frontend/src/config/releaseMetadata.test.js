import { describe, expect, it, vi } from 'vitest'
import { releaseMetadataPlugin, resolveRevision } from '../../config/releaseMetadata'

describe('release source metadata', () => {
  it('uses the hosting build commit before a stale manual release', () => {
    expect(resolveRevision({ COMMIT_REF: 'A'.repeat(40), VITE_SENTRY_RELEASE: 'b'.repeat(40) }, 'c'.repeat(40)))
      .toBe('a'.repeat(40))
  })

  it('supports a local checkout and a source archive with an explicit commit', () => {
    expect(resolveRevision({}, 'c'.repeat(40))).toBe('c'.repeat(40))
    expect(resolveRevision({ VITE_APP_REVISION: 'd'.repeat(64) }, null)).toBe('d'.repeat(64))
  })

  it('keeps an unknown or invalid authoritative source explicit', () => {
    expect(resolveRevision({}, null)).toBeNull()
    expect(resolveRevision({ COMMIT_REF: 'not-a-commit', VITE_APP_REVISION: 'a'.repeat(40) }, 'b'.repeat(40))).toBeNull()
  })

  it('emits only the nonsecret revision in the build artifact', () => {
    const emitFile = vi.fn()
    releaseMetadataPlugin('a'.repeat(40)).generateBundle.call({ emitFile })
    expect(emitFile).toHaveBeenCalledWith({ type: 'asset', fileName: 'release.json', source: JSON.stringify({ revision: 'a'.repeat(40) }) })
  })
})
