import { describe, expect, it } from 'vitest'
import { organizerChecklist } from './organizerChecklist'

describe('organizer launch checklist', () => {
  it('keeps concrete steps and groups every internal or new release restriction into the launch review', () => {
    const checklist = [{ code: 'title', label: 'Title', complete: true }, { code: 'tickets', complete: false }, { code: 'live_money_approved', complete: true }, { code: 'new_platform_gate', complete: false }]
    const steps = organizerChecklist(checklist)
    expect(steps.find(item => item.code === 'tickets')).toMatchObject({ label: 'Add at least one ticket type', href: '#ticket-types', complete: false })
    expect(steps.find(item => item.code === 'launch_review').complete).toBe(false)
    expect(steps.some(item => item.label?.includes('live_money'))).toBe(false)
    expect(checklist.every(item => item.complete)).toBe(false)
  })
})
