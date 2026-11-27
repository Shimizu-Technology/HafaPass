import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  DEFAULT_POSTHOG_HOST,
  buildPostHogOptions,
  capturePostHogPageView,
  initPostHog,
  isPlaceholderPostHogKey,
  isPostHogEnabled,
  isPostHogInitialized,
  resetPostHogStateForTests,
  sanitizePostHogProperties,
  sanitizeUrlForAnalytics,
} from './posthog'

afterEach(() => {
  resetPostHogStateForTests()
})

describe('PostHog configuration and gating', () => {
  it('treats missing, empty, and placeholder keys as invalid', () => {
    expect(isPlaceholderPostHogKey(undefined)).toBe(true)
    expect(isPlaceholderPostHogKey('')).toBe(true)
    expect(isPlaceholderPostHogKey('   ')).toBe(true)
    expect(isPlaceholderPostHogKey('phc_xxx')).toBe(true)
    expect(isPlaceholderPostHogKey('phc_your_project_api_key')).toBe(true)
    expect(isPlaceholderPostHogKey('placeholder')).toBe(true)
    expect(isPlaceholderPostHogKey('<posthog-key>')).toBe(true)
    expect(isPlaceholderPostHogKey('phc_AbCdEf1234567890RealKey')).toBe(false)
  })

  it('stays disabled when key is missing or placeholder', () => {
    const mockClient = { init: vi.fn(), capture: vi.fn() }

    expect(initPostHog({ PROD: true, VITE_PUBLIC_POSTHOG_KEY: '' }, mockClient)).toBe(false)
    expect(initPostHog({ PROD: true, VITE_PUBLIC_POSTHOG_KEY: 'phc_xxx' }, mockClient)).toBe(false)
    expect(mockClient.init).not.toHaveBeenCalled()
    expect(isPostHogInitialized()).toBe(false)
  })

  it('stays disabled in development unless VITE_ENABLE_ANALYTICS_IN_DEV is true', () => {
    expect(isPostHogEnabled({
      PROD: false,
      VITE_PUBLIC_POSTHOG_KEY: 'phc_RealProductionKey123',
    })).toBe(false)

    expect(isPostHogEnabled({
      PROD: false,
      VITE_PUBLIC_POSTHOG_KEY: 'phc_RealProductionKey123',
      VITE_ENABLE_ANALYTICS_IN_DEV: 'true',
    })).toBe(true)
  })

  it('stays disabled in demo-data mode even in production', () => {
    expect(isPostHogEnabled({
      PROD: true,
      VITE_HAFAPASS_DEMO_DATA: '1',
      VITE_PUBLIC_POSTHOG_KEY: 'phc_RealProductionKey123',
    })).toBe(false)
  })

  it('initializes with masked session replay, manual pageviews, and URL sanitization', () => {
    const mockClient = { init: vi.fn(), capture: vi.fn() }

    const didInit = initPostHog({
      PROD: true,
      VITE_PUBLIC_POSTHOG_KEY: '  phc_RealProductionKey123  ',
    }, mockClient)

    expect(didInit).toBe(true)
    expect(mockClient.init).toHaveBeenCalledTimes(1)
    expect(mockClient.init).toHaveBeenCalledWith(
      'phc_RealProductionKey123',
      expect.objectContaining({
        api_host: DEFAULT_POSTHOG_HOST,
        capture_pageview: false,
        capture_pageleave: true,
        autocapture: true,
        disable_session_recording: false,
        session_recording: {
          maskAllInputs: true,
          blockClass: 'ph-no-capture',
        },
        sanitize_properties: sanitizePostHogProperties,
      }),
    )
  })

  it('respects custom VITE_PUBLIC_POSTHOG_HOST', () => {
    const options = buildPostHogOptions({
      VITE_PUBLIC_POSTHOG_HOST: 'https://eu.i.posthog.com',
    })
    expect(options.api_host).toBe('https://eu.i.posthog.com')
  })

  it('redacts sensitive query params, hash params, and credential path segments', () => {
    const raw = 'https://hafapass.app/checkout/guam-fest?event=123&token=secret_tok&session_id=cs_live_123&payment_intent=pi_123&payment_intent_client_secret=pi_123_secret_abc&code=oauth_code&state=oauth_state&email=buyer%40example.com&utm_source=ig#token=hash_tok&section=summary'
    const sanitized = sanitizeUrlForAnalytics(raw)

    expect(sanitized).toBe('https://hafapass.app/checkout/guam-fest?event=123&utm_source=ig#section=summary')
    expect(sanitized).not.toContain('secret_tok')
    expect(sanitized).not.toContain('cs_live_123')
    expect(sanitized).not.toContain('pi_123')
    expect(sanitized).not.toContain('oauth_code')
    expect(sanitized).not.toContain('oauth_state')
    expect(sanitized).not.toContain('buyer')
    expect(sanitized).not.toContain('hash_tok')

    expect(sanitizeUrlForAnalytics('https://hafapass.app/tickets/cred-secret-999?token=abc')).toBe(
      'https://hafapass.app/tickets/[redacted]',
    )
    expect(sanitizeUrlForAnalytics('https://hafapass.app/unsubscribe/unsub-secret-1')).toBe(
      'https://hafapass.app/unsubscribe/[redacted]',
    )
    expect(sanitizeUrlForAnalytics('https://hafapass.app/email-confirm/tok-1')).toBe(
      'https://hafapass.app/email-confirm/[redacted]',
    )
  })

  it('redacts sensitive fields and URLs inside sanitizePostHogProperties', () => {
    const cleaned = sanitizePostHogProperties({
      $current_url: 'https://hafapass.app/orders/42/confirmation?payment_intent_client_secret=pi_secret&session_id=cs_123&tab=tickets',
      $referrer: 'https://hafapass.app/checkout/event-1?email=test@example.com',
      $pathname: '/tickets/secret-credential',
      email: 'test@example.com',
      token: 'raw-token',
      safe_prop: 'ok',
    })

    expect(cleaned).toEqual({
      $current_url: 'https://hafapass.app/orders/42/confirmation?tab=tickets',
      $referrer: 'https://hafapass.app/checkout/event-1',
      $pathname: '/tickets/[redacted]',
      email: '[redacted]',
      token: '[redacted]',
      safe_prop: 'ok',
    })
  })

  it('captures pageview only after initialization and redacts sensitive params', () => {
    const mockClient = { init: vi.fn(), capture: vi.fn() }

    expect(capturePostHogPageView({ pathname: '/events', search: '', hash: '' }, mockClient)).toBe(false)
    expect(mockClient.capture).not.toHaveBeenCalled()

    initPostHog({
      PROD: true,
      VITE_PUBLIC_POSTHOG_KEY: 'phc_RealProductionKey123',
    }, mockClient)

    const captured = capturePostHogPageView({
      pathname: '/orders/99/confirmation',
      search: '?payment_intent=pi_123&payment_intent_client_secret=secret_456&view=receipt',
      hash: '',
    }, mockClient)

    expect(captured).toBe(true)
    expect(mockClient.capture).toHaveBeenCalledWith('$pageview', {
      $current_url: `${window.location.origin}/orders/99/confirmation?view=receipt`,
    })
  })
})
