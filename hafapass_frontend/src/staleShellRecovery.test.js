import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { cwd } from 'node:process'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

// The guard lives inline in index.html so it runs before any bundled script.
const guardSource = readFileSync(join(cwd(), 'index.html'), 'utf8')
  .match(/<!-- stale-shell-recovery[\s\S]*?<script>([\s\S]*?)<\/script>/)[1]
const installGuard = () => new Function(guardSource)()

function failAsset(tagName, url) {
  const element = document.createElement(tagName)
  if (tagName === 'script') element.src = url
  else element.href = url
  document.head.appendChild(element)
  element.dispatchEvent(new Event('error'))
  element.remove()
}

describe('stale shell recovery', () => {
  const reload = vi.fn()
  let originalLocation

  beforeEach(() => {
    window.sessionStorage.clear()
    reload.mockReset()
    originalLocation = window.location
    Object.defineProperty(window, 'location', { configurable: true, value: { ...originalLocation, reload } })
    installGuard()
  })

  afterEach(() => {
    Object.defineProperty(window, 'location', { configurable: true, value: originalLocation })
  })

  it('reloads once when a release asset fails to load, not again within a minute', () => {
    failAsset('script', 'https://example.test/assets/index-old.js')
    expect(reload).toHaveBeenCalledTimes(1)
    failAsset('link', 'https://example.test/assets/index-old.css')
    expect(reload).toHaveBeenCalledTimes(1)
  })

  it('recovers from a lazy chunk that disappeared after a deploy', () => {
    const event = new Event('vite:preloadError', { cancelable: true })
    window.dispatchEvent(event)
    expect(reload).toHaveBeenCalledTimes(1)
    expect(event.defaultPrevented).toBe(true)
  })

  it('ignores failures outside the release assets', () => {
    failAsset('script', 'https://example.test/vendor/analytics.js')
    expect(reload).not.toHaveBeenCalled()
  })
})
