import { describe, expect, it } from 'vitest'
import { blocksPublishing, organizerChecklist } from './organizerChecklist'

describe('organizer launch checklist', () => {
  it('keeps concrete steps and drops retired or unknown review codes', () => {
    const checklist = [{ code: 'title', label: 'Title', complete: true }, { code: 'tickets', complete: false }, { code: 'live_money_approved', complete: false }, { code: 'new_platform_gate', complete: false }]
    const steps = organizerChecklist(checklist)
    expect(steps.find(item => item.code === 'tickets')).toMatchObject({ label: 'Add at least one ticket type', href: '#ticket-types', complete: false })
    expect(steps.map(item => item.code)).toEqual(['title', 'tickets'])
    expect(steps.some(item => /launch review|live_money/i.test(item.label))).toBe(false)
  })

  it('shows organizer verification as one plain step with a request action instead of a link', () => {
    const [waiting] = organizerChecklist([{ code: 'organizer_verified', label: 'Organizer identity verified', complete: false }])
    expect(waiting).toMatchObject({ label: 'Waiting for HåfaPass to verify your organization before tickets go on sale', href: null, requestVerification: true })
    const [verified] = organizerChecklist([{ code: 'organizer_verified', complete: true }])
    expect(verified).toMatchObject({ label: 'HåfaPass verified your organization', requestVerification: false })
  })

  it('uses plain payout copy', () => {
    expect(organizerChecklist([{ code: 'payout', complete: false }])[0]).toMatchObject({ label: 'Complete Tax information and How you get paid in Settings, then wait for finance approval.', href: '/dashboard/settings' })
    expect(organizerChecklist([{ code: 'payout', complete: true }])[0].label).toBe('Paid-ticket setup approved, or not needed for free tickets')
  })

  it('only lets items marked not required to publish through', () => {
    expect(blocksPublishing({ code: 'organizer_verified', required_to_publish: false })).toBe(false)
    expect(blocksPublishing({ code: 'organizer_verified', required_to_publish: true })).toBe(true)
    expect(blocksPublishing({ code: 'title' })).toBe(true)
  })
})
