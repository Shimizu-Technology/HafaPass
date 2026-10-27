import { beforeEach, describe, expect, it, vi } from 'vitest'
import { canReloadForRelease, createReleaseReloadPolicy, RELEASE_RELOAD_PREFIX, trackUnsavedInputs } from './releaseUpdate'

const A = 'a'.repeat(40)
const B = 'b'.repeat(40)
beforeEach(() => sessionStorage.clear())

describe('release reload policy', () => {
  it.each(['/', '/events', '/HOST/', '/discover', '/collections', '/about', '/policies/refunds'])('reloads on a public safe route: %s', pathname => {
    expect(canReloadForRelease({ pathname })).toBe(true)
  })
  it.each(['/checkout/test', '/%63heckout/test', '/orders/1/confirmation', '/orders/recover', '/payments/return', '/ticket-transfers/accept', '/tickets/secret', '/dashboard/scanner', '/dashboard/events/1/box-office', '/unsubscribe', '/unsubscribe/token', '/events/show', '/events/show/preview'])('protects %s, even hidden or following navigation', pathname => {
    expect(canReloadForRelease({ pathname, hidden: true, navigated: true, notFound: true })).toBe(false)
  })
  function fixture(pathname = '/') {
    const state = { pathname, navigationKey: 'initial' }
    const reload = vi.fn()
    const policy = createReleaseReloadPolicy({ currentRevision: A, storage: sessionStorage, reload, getState: () => state })
    return { state, reload, policy }
  }
  it('defers checkout through confirmation and reloads on the next safe navigation', () => {
    const { state, reload, policy } = fixture('/checkout/show')
    policy.notice(B)
    Object.assign(state, { pathname: '/orders/1/confirmation', navigationKey: 'confirmation' })
    policy.attempt()
    expect(reload).not.toHaveBeenCalled()
    Object.assign(state, { pathname: '/events', navigationKey: 'events' })
    policy.attempt()
    expect(reload).toHaveBeenCalledTimes(1)
  })
  it('waits for a navigation after the update, rather than any earlier navigation', () => {
    const { state, reload, policy } = fixture('/nontransactional')
    state.navigationKey = 'earlier-navigation'
    policy.notice(B)
    policy.notice(B)
    expect(reload).not.toHaveBeenCalled()
    state.navigationKey = 'later-navigation'
    policy.attempt()
    expect(reload).toHaveBeenCalledTimes(1)
  })
  it('keeps event selection protected through hidden state and query changes until departure', () => {
    const { state, reload, policy } = fixture('/events/show')
    policy.notice(B)
    Object.assign(state, { hidden: true, navigationKey: 'changed-query' })
    policy.attempt()
    expect(reload).not.toHaveBeenCalled()
    Object.assign(state, { pathname: '/', navigationKey: 'home' })
    policy.attempt()
    expect(reload).toHaveBeenCalledTimes(1)
  })
  it('reloads a nontransactional hidden page and the rendered not-found page', () => {
    expect(canReloadForRelease({ pathname: '/nontransactional', hidden: true })).toBe(true)
    expect(canReloadForRelease({ pathname: '/unknown', notFound: true })).toBe(true)
  })
  it('never reloads an unsaved draft, even hidden on Home; leaving permits the update', () => {
    const { state, reload, policy } = fixture()
    state.unsaved = true
    state.hidden = true
    policy.notice(B)
    expect(reload).not.toHaveBeenCalled()
    state.unsaved = false
    state.navigationKey = 'after-saving-or-leaving'
    policy.attempt()
    expect(reload).toHaveBeenCalledTimes(1)
  })
  it('guards each revision across policy instances and ignores the loaded revision', () => {
    const first = fixture()
    first.policy.notice(A)
    expect(first.reload).not.toHaveBeenCalled()
    first.policy.notice(B)
    first.policy.attempt()
    expect(first.reload).toHaveBeenCalledTimes(1)
    expect(sessionStorage.getItem(RELEASE_RELOAD_PREFIX + B)).toBe('1')
    const second = fixture()
    second.policy.notice(B)
    expect(second.reload).not.toHaveBeenCalled()
    second.policy.notice('c'.repeat(40))
    expect(second.reload).toHaveBeenCalledTimes(1)
  })
  it('fails closed if storage cannot keep the guard', () => {
    const reload = vi.fn()
    createReleaseReloadPolicy({ currentRevision: A, storage: { getItem() { throw Error('denied') } }, reload, getState: () => ({ pathname: '/' }) }).notice(B)
    expect(reload).not.toHaveBeenCalled()
  })
})

it('protects unregistered input until unmount, including controlled inputs and cancelled resets', () => {
  const tracker = trackUnsavedInputs(document)
  const form = document.createElement('form')
  const input = document.createElement('input')
  form.append(input)
  document.body.append(form)
  input.value = 'Unsaved'
  input.dispatchEvent(new Event('input', { bubbles: true }))
  input.defaultValue = input.value
  expect(tracker.hasUnsaved()).toBe(true)
  form.addEventListener('reset', event => event.preventDefault())
  form.reset()
  expect(tracker.hasUnsaved()).toBe(true)
  input.dispatchEvent(new Event('change', { bubbles: true }))
  form.remove()
  expect(tracker.hasUnsaved()).toBe(false)
  tracker.dispose()
})
