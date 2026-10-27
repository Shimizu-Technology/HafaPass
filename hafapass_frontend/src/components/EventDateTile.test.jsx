import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import EventDateTile from './EventDateTile'

describe('EventDateTile', () => {
  it.each([
    ['2026-10-31T13:59:59Z', 'Saturday, Oct 31, 2026', 'Sat', '31', 'Oct'],
    ['2026-10-31T14:00:00Z', 'Sunday, Nov 1, 2026', 'Sun', '1', 'Nov'],
    ['2026-12-31T14:00:00Z', 'Friday, Jan 1, 2027', 'Fri', '1', 'Jan'],
  ])('uses Guam time across midnight for %s', (starts_at, label, weekday, day, month) => {
    render(<EventDateTile event={{ starts_at }} />)
    expect(screen.getByLabelText(label)).toHaveAttribute('datetime', starts_at)
    for (const part of [weekday, day, month]) expect(screen.getByText(part)).toBeInTheDocument()
  })

  it('respects the event timezone when provided', () => {
    render(<EventDateTile event={{ starts_at: '2026-10-31T14:00:00Z', timezone: 'Pacific/Honolulu' }} />)
    expect(screen.getByLabelText('Saturday, Oct 31, 2026')).toBeInTheDocument()
  })

  it('does not render a misleading date when the start time is missing', () => {
    const { container } = render(<EventDateTile event={{}} />)
    expect(container).toBeEmptyDOMElement()
  })
})
