import { act, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import {
  loadSupportContact, resetSupportContactForTests, setSupportContact, supportMailto, supportTel, useSupportContact,
} from './supportContact'

vi.mock('../api/client', () => ({ default: { get: vi.fn() } }))

beforeEach(() => {
  window.localStorage.clear()
  resetSupportContactForTests()
  apiClient.get.mockReset()
})
afterEach(() => vi.unstubAllEnvs())

describe('support contact configuration', () => {
  it('uses the configured operator mailbox and safely encodes order context', () => {
    vi.stubEnv('VITE_SUPPORT_EMAIL', ' support+finance@example.test ')
    const subject = 'Refund review for order HP-A&B / #42?'
    const href = supportMailto(subject)
    expect(href).toBe(`mailto:support%2Bfinance@example.test?subject=${encodeURIComponent(subject)}`)
    expect(new URL(href).searchParams.get('subject')).toBe(subject)
    expect([...new URL(href).searchParams.keys()]).toEqual(['subject'])
  })

  it('uses the admin-managed support contact from /config', async () => {
    vi.stubEnv('VITE_SUPPORT_EMAIL', '')
    apiClient.get.mockResolvedValue({ data: { support_email: 'help@example.test', support_phone: '+1 (671) 555-0100' } })

    await loadSupportContact()

    expect(apiClient.get).toHaveBeenCalledWith('/config')
    expect(supportMailto()).toBe('mailto:help@example.test?subject=H%C3%A5faPass%20Support')
    expect(supportTel()).toBe('tel:+16715550100')
  })

  it('lets the build-time override win over the configured contact', () => {
    vi.stubEnv('VITE_SUPPORT_EMAIL', 'override@example.test')
    setSupportContact({ email: 'help@example.test' })
    expect(supportMailto()).toBe('mailto:override@example.test?subject=H%C3%A5faPass%20Support')
  })

  it.each([undefined, '', '   ', 'not-an-email'])('leads to in-app help when nothing usable is configured (%s)', value => {
    vi.stubEnv('VITE_SUPPORT_EMAIL', '')
    setSupportContact({ email: value })
    expect(supportMailto()).toBe('/orders/recover')
    expect(supportTel()).toBe('')
  })

  it('keeps the last known contact for outages and forgets a cleared one', async () => {
    vi.stubEnv('VITE_SUPPORT_EMAIL', '')
    setSupportContact({ email: 'help@example.test' })
    expect(JSON.parse(window.localStorage.getItem('hafapass_support_contact'))).toEqual({ email: 'help@example.test', phone: '' })

    apiClient.get.mockResolvedValue({ data: { support_email: null, support_phone: null } })
    await loadSupportContact()
    expect(window.localStorage.getItem('hafapass_support_contact')).toBeNull()
    expect(supportMailto()).toBe('/orders/recover')
  })

  it('retries after a failed load and survives a client that returns nothing', async () => {
    apiClient.get.mockReturnValueOnce(undefined).mockRejectedValueOnce(new Error('offline'))
    await loadSupportContact()
    await loadSupportContact()
    vi.stubEnv('VITE_SUPPORT_EMAIL', '')
    expect(supportMailto()).toBe('/orders/recover')
    apiClient.get.mockResolvedValue({ data: { support_email: 'help@example.test' } })
    await loadSupportContact()
    expect(apiClient.get).toHaveBeenCalledTimes(3)
    expect(supportMailto()).toBe('mailto:help@example.test?subject=H%C3%A5faPass%20Support')
  })

  it('re-renders links once the configured contact arrives', async () => {
    vi.stubEnv('VITE_SUPPORT_EMAIL', '')
    let resolve
    apiClient.get.mockReturnValue(new Promise(done => { resolve = done }))
    function Contact() {
      const { mailto } = useSupportContact()
      return <a href={mailto()}>Contact support</a>
    }
    render(<Contact />)
    expect(screen.getByRole('link', { name: 'Contact support' })).toHaveAttribute('href', '/orders/recover')

    await act(async () => { resolve({ data: { support_email: 'help@example.test' } }) })

    expect(screen.getByRole('link', { name: 'Contact support' })).toHaveAttribute('href', 'mailto:help@example.test?subject=H%C3%A5faPass%20Support')
  })
})
