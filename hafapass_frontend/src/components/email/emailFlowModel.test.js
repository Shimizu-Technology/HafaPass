import { describe, expect, it } from 'vitest'
import i18n from '../../i18n'
import { audienceBreakdown, canCancel, countValues, deliveryTotals, describeFilters, errorKey, mailingState, scheduleLapsed, zeroReason } from './emailFlowModel'

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
    expect(t('emailFlow.send.confirmNowTitle', countValues(1))).toBe('Send to about 1 person now?')
    expect(t('emailFlow.send.confirmLaterTitle', countValues(48000))).toBe('Schedule for about 48,000 people?')
    expect(t('emailFlow.send.estimate', countValues(1))).toBe('About 1 person (final count when it sends)')
    expect(t('emailFlow.send.estimate', countValues(48000))).toBe('About 48,000 people (final count when it sends)')
    expect(t('emailFlow.history.outcome.skipped', countValues(1))).toBe('1 skipped (unsubscribed or blocked by send time)')
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

  it('#minor: shows no platform reasons until the API sends status_breakdown', () => {
    expect(audienceBreakdown({ eligible: 5, considered: 9 }, 'platform')).toEqual({ eligible: 5, considered: 9, excluded: 4, reasons: [] })
  })

  it('#2: never promises the final count can only go down', () => {
    expect(t('emailFlow.count.recheck')).toBe('We check everyone again when it sends, so the final number can go up or down.')
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
    [{ status: 'queued', recipient_count: 50, counts: { suppressed: 48, failed: 2 } }, 'notDelivered'],
    [{ status: 'queued', recipient_count: 2, counts: { bounced: 2 } }, 'notDelivered'],
    [{ status: 'queued', recipient_count: 0, counts: {} }, 'notDelivered'],
    [{ status: 'queued', recipient_count: 290, counts: { delivered: 280, suppressed: 10 } }, 'partial'],
    // Review round 2 #3: mixed outcomes.
    [{ status: 'queued', recipient_count: 10, handed_off: 10, counts: { delivered: 1, bounced: 9 } }, 'partial'],
    [{ status: 'queued', recipient_count: 5, counts: { sent: 3, failed: 2 } }, 'partial'],
    [{ status: 'queued', recipient_count: 5, handed_off: 2, counts: { failed: 5 } }, 'notDelivered'],
    [{ status: 'queued', recipient_count: 5, counts: { sent: 5 } }, 'sent'],
    [{ status: 'queued', recipient_count: 2, counts: { delivered: 1, complained: 1 } }, 'sent'],
    [{ status: 'blocked' }, 'notSent'],
    [{ status: 'cancelled' }, 'cancelled'],
  ])('%o is %s', (row, expected) => expect(mailingState(row, now)).toBe(expected))

  it('groups provider statuses into delivery totals', () => {
    expect(deliveryTotals({ status: 'queueing', recipient_count: 48000, counts: { queued: 46800, sent: 900, delivered: 288, bounced: 12 }, unsubscribed: 1 }))
      .toEqual({ recipients: 48000, queued: 46800, accepted: 900, delivered: 288, spam: 0, bounced: 12, failed: 0, skipped: 0,
        handedOff: 1200, processed: 1200, notSent: 0, arrived: 288, problems: 12, waiting: 47700, unsubscribed: 1 })
  })

  it('#4: never counts suppressed or failed deliveries as handed to the email service', () => {
    expect(deliveryTotals({ status: 'queueing', recipient_count: 100, counts: { queued: 50, sent: 30, suppressed: 15, failed: 5 } }))
      .toMatchObject({ handedOff: 30, notSent: 20, processed: 50, recipients: 100 })
  })

  it('round 2 #3: takes handed-off counts from provider acceptance evidence when the API sends it', () => {
    expect(deliveryTotals({ status: 'queued', recipient_count: 13, handed_off: 11, counts: { delivered: 1, bounced: 9, failed: 2, suppressed: 1 } }))
      .toMatchObject({ processed: 13, handedOff: 11, notSent: 2, problems: 12, arrived: 1 })
  })

  it('round 2 #1: recognizes the server lapsed-schedule refusal', () => {
    expect(errorKey({ response: { status: 422, data: { error: 'Schedule lapsed', code: 'schedule_lapsed' } } })).toBe('scheduleLapsed')
  })

  it('#2: uses the job’s recorded recipient count once sending starts, and no count before', () => {
    expect(deliveryTotals({ status: 'queued', recipient_count: 290, counts: { delivered: 280 } }).recipients).toBe(290)
    expect(deliveryTotals({ status: 'scheduled', recipient_count: 0, counts: {} }).recipients).toBe(0)
  })

  it('#5: offers cancel whenever the server status is scheduled, even past its time', () => {
    expect(canCancel({ status: 'scheduled', scheduled_at: '2020-01-01T00:00:00Z' })).toBe(true)
    expect(['draft', 'queueing', 'queued', 'cancelled', 'blocked'].map(status => canCancel({ status }))).toEqual([false, false, false, false, false])
  })

  it('#3: treats a time in the past or within a minute as lapsed', () => {
    expect(scheduleLapsed('2026-11-23T23:59:00Z', now)).toBe(true)
    expect(scheduleLapsed('2026-11-24T00:00:30Z', now)).toBe(true)
    expect(scheduleLapsed('2026-11-24T00:02:00Z', now)).toBe(false)
    expect(scheduleLapsed('', now)).toBe(true)
  })

  it('describes saved filters and API errors in words', () => {
    expect(describeFilters(t, { source: 'checkout', status: 'pending', q: 'avery' })).toBe('Search by email: avery, Signup status: Not confirmed yet, Signed up from: Checkout')
    expect(describeFilters(t, { source: 'checkout', q: 'x' }, 'organizer')).toBe('Search by email: x')
    expect(errorKey({ response: { status: 422, data: { error: 'Certified postal address required' } } })).toBe('addressMissing')
    expect(errorKey({ response: { status: 409 } })).toBe('conflict')
    expect(errorKey(new Error('offline'))).toBe('generic')
  })
})
