import { describe, expect, it } from 'vitest'
import i18n from '../../i18n'
import { audienceBreakdown, countValues, deliveryTotals, describeFilters, errorKey, mailingState, zeroReason } from './emailFlowModel'

const t = i18n.t.bind(i18n)

describe('plural copy', () => {
  it.each([
    [0, '0 people will get this email'],
    [1, '1 person will get this email'],
    [2, '2 people will get this email'],
    [48000, '48,000 people will get this email'],
  ])('willGet %i', (count, text) => expect(t('emailFlow.count.willGet', countValues(count))).toBe(text))

  it('pluralizes every counted string at 1 and many', () => {
    expect(t('emailFlow.count.leftOut', countValues(1))).toBe('1 person left out')
    expect(t('emailFlow.count.leftOut', countValues(1250))).toBe('1,250 people left out')
    expect(t('emailFlow.count.pending', countValues(1))).toBe('1 hasn’t confirmed their signup yet')
    expect(t('emailFlow.count.pending', countValues(3))).toBe('3 haven’t confirmed their signup yet')
    expect(t('emailFlow.send.confirmNowTitle', countValues(1))).toBe('Send to 1 person now?')
    expect(t('emailFlow.send.confirmLaterTitle', countValues(48000))).toBe('Schedule for 48,000 people?')
    expect(t('emailFlow.history.recipients', countValues(1))).toBe('1 recipient')
    expect(t('emailFlow.history.recipients', countValues(2))).toBe('2 recipients')
    expect(t('emailFlow.filters.active', countValues(1))).toBe('1 filter on')
    expect(t('emailFlow.people.growth', countValues(1))).toBe('1 new signup in the last 90 days')
  })
})

describe('audienceBreakdown', () => {
  it('explains platform exclusions from the filtered status breakdown', () => {
    const result = audienceBreakdown({ eligible: 312, considered: 336, status_breakdown: { confirmed: 314, pending: 9, unsubscribed: 7, bounced: 4, complained: 2 } }, 'platform')
    expect(result).toEqual({ eligible: 312, considered: 336, excluded: 24, reasons: [
      { key: 'pending', count: 9 }, { key: 'unsubscribed', count: 7 }, { key: 'bounced', count: 6 }, { key: 'blocked', count: 2 },
    ] })
  })

  it('uses one organizer reason and tolerates older responses without considered', () => {
    expect(audienceBreakdown({ eligible: 212, considered: 540 }, 'organizer').reasons).toEqual([{ key: 'noConsent', count: 328 }])
    expect(audienceBreakdown({ eligible: 5, count: 5 }, 'organizer')).toMatchObject({ excluded: 0, reasons: [] })
    expect(audienceBreakdown(null, 'platform')).toBeNull()
  })

  it('classifies zero states', () => {
    expect(zeroReason({ list: { eligible: 0, considered: 0 }, scope: 'platform', filterCount: 0 })).toBe('emptyList')
    expect(zeroReason({ list: { eligible: 0, considered: 0 }, scope: 'platform', filterCount: 2 })).toBe('filtered')
    expect(zeroReason({ list: { eligible: 0, considered: 37 }, scope: 'organizer', filterCount: 0 })).toBe('allLeftOut')
    expect(zeroReason({ list: { eligible: 1, considered: 1 }, scope: 'organizer', filterCount: 0 })).toBeNull()
  })
})

describe('history', () => {
  const now = Date.parse('2026-11-24T00:00:00Z')
  it.each([
    [{ status: 'draft' }, 'draft'],
    [{ status: 'scheduled', scheduled_at: '2026-11-25T00:00:00Z' }, 'scheduled'],
    [{ status: 'scheduled', scheduled_at: '2026-11-23T00:00:00Z' }, 'starting'],
    [{ status: 'queueing' }, 'sending'],
    [{ status: 'queued', counts: { queued: 3 } }, 'sending'],
    [{ status: 'queued', counts: { delivered: 3 } }, 'sent'],
    [{ status: 'blocked' }, 'notSent'],
    [{ status: 'cancelled' }, 'cancelled'],
  ])('%o is %s', (row, expected) => expect(mailingState(row, now)).toBe(expected))

  it('groups provider statuses into delivery totals', () => {
    expect(deliveryTotals({ recipient_count: 48000, counts: { queued: 46800, sent: 900, delivered: 288, bounced: 12 }, unsubscribed: 1 }))
      .toEqual({ recipients: 48000, delivered: 288, waiting: 47700, bounced: 12, spam: 0, notSent: 0, unsubscribed: 1, processed: 1200 })
  })

  it('describes saved filters and API errors in words', () => {
    expect(describeFilters(t, { source: 'checkout', status: 'pending', q: 'avery' })).toBe('Search by email: avery, Signup status: Not confirmed yet, Signed up from: Checkout')
    expect(describeFilters(t, { source: 'checkout', q: 'x' }, 'organizer')).toBe('Search by email: x')
    expect(errorKey({ response: { status: 422, data: { error: 'Certified postal address required' } } })).toBe('addressMissing')
    expect(errorKey({ response: { status: 409 } })).toBe('conflict')
    expect(errorKey(new Error('offline'))).toBe('generic')
  })
})
