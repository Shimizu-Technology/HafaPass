import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { describe, expect, it } from 'vitest'
import PassTicketCard from './PassTicketCard'
import { getChildNightStatus, selectSpotlightNight } from '../utils/passTicket'

const baseParent = {
  id: 100,
  status: 'issued',
  is_pass: true,
  pass_parent: true,
  pass_child: false,
  pass_nights_count: 5,
  attendee_name: 'Juan Cruz',
  ticket_type: { id: 10, name: 'FD Season Pass' },
  event: { id: 1, title: 'FD Tourney 2026', slug: 'fd-tourney-2026', timezone: 'Pacific/Guam', status: 'published' },
  child_tickets: [
    {
      id: 101,
      parent_ticket_id: 100,
      status: 'checked_in',
      checked_in_at: '2026-11-21T08:15:00Z',
      admission_allowed: false,
      admission_block_reason: null,
      display_credential: 'child-night-1',
      display_token: 'child-night-1',
      ticket_url: '/tickets/child-night-1',
      event: { id: 11, title: 'Opening Night', slug: 'opening-night', starts_at: '2026-11-21T08:00:00Z', ends_at: '2026-11-21T12:00:00Z', timezone: 'Pacific/Guam', status: 'published', venue_name: 'FD Jungle' },
    },
    {
      id: 102,
      parent_ticket_id: 100,
      status: 'issued',
      admission_allowed: true,
      admission_block_reason: null,
      display_credential: 'child-night-2',
      display_token: 'child-night-2',
      ticket_url: '/tickets/child-night-2',
      event: { id: 12, title: 'Night 2 Showdown', slug: 'night-2', starts_at: '2026-11-22T09:00:00Z', ends_at: '2026-11-22T12:00:00Z', timezone: 'Pacific/Guam', status: 'published', venue_name: 'FD Jungle' },
    },
    {
      id: 103,
      parent_ticket_id: 100,
      status: 'issued',
      admission_allowed: false,
      admission_block_reason: 'Event is postponed',
      display_credential: 'child-night-3',
      display_token: 'child-night-3',
      ticket_url: '/tickets/child-night-3',
      event: { id: 13, title: 'Storm Night', slug: 'storm-night', starts_at: '2026-11-23T09:00:00Z', ends_at: '2026-11-23T12:00:00Z', timezone: 'Pacific/Guam', status: 'postponed', venue_name: 'FD Jungle' },
    },
    {
      id: 104,
      parent_ticket_id: 100,
      status: 'cancelled',
      admission_allowed: false,
      admission_block_reason: null,
      display_credential: 'child-night-4',
      display_token: 'child-night-4',
      ticket_url: '/tickets/child-night-4',
      event: { id: 14, title: 'Cancelled Exhibition', slug: 'cancelled-exhibition', starts_at: '2026-11-24T09:00:00Z', ends_at: '2026-11-24T12:00:00Z', timezone: 'Pacific/Guam', status: 'cancelled', venue_name: 'FD Jungle' },
    },
    {
      id: 105,
      parent_ticket_id: 100,
      status: 'issued',
      admission_allowed: false,
      admission_block_reason: 'Ticket access is paused while its refund is pending',
      display_credential: 'child-night-5',
      display_token: 'child-night-5',
      ticket_url: '/tickets/child-night-5',
      event: { id: 15, title: 'Finals Night', slug: 'finals-night', starts_at: '2026-11-25T09:00:00Z', ends_at: '2026-11-25T12:00:00Z', timezone: 'Pacific/Guam', status: 'published', venue_name: 'FD Jungle' },
    },
  ],
}

describe('PassTicketCard', () => {
  it("spotlights Tonight's Ticket in Pacific/Guam timezone without rendering any parent QR code", () => {
    // 2026-11-22T05:00:00Z is 2026-11-22 15:00 ChST (Guam) — same local day as Night 2 (2026-11-22T09:00:00Z = 19:00 ChST)
    const guamToday = new Date('2026-11-22T05:00:00Z')
    const { container } = render(
      <MemoryRouter>
        <PassTicketCard ticket={baseParent} orderId="77" now={guamToday} />
      </MemoryRouter>,
    )

    expect(screen.getByText('Multi-Night Pass · 5 nights')).toBeInTheDocument()
    expect(screen.getByText("Tonight's Ticket")).toBeInTheDocument()
    expect(screen.getByText('Night 2 Showdown')).toBeInTheDocument()
    expect(screen.getByText('Tonight')).toBeInTheDocument()

    const doorLink = screen.getByRole('link', { name: /Open Door QR \/ Ticket/ })
    expect(doorLink).toHaveAttribute('href', '/tickets/child-night-2?order=77')

    // Never renders a scannable QR canvas or svg for the parent container
    expect(container.querySelector('canvas')).toBeNull()
    expect(screen.queryByText('Entry QR')).not.toBeInTheDocument()
  })

  it('falls back to Next Included Night when no night is today in Pacific/Guam', () => {
    // 2026-11-21T15:00:00Z is 2026-11-22 01:00 ChST? Wait: 2026-11-20T05:00:00Z is 2026-11-20 15:00 ChST (day before Opening Night)
    const beforeEvent = new Date('2026-11-20T05:00:00Z')
    render(
      <MemoryRouter>
        <PassTicketCard ticket={baseParent} now={beforeEvent} />
      </MemoryRouter>,
    )

    expect(screen.getByText('Next Included Night')).toBeInTheDocument()
    expect(screen.getByText('Night 2 Showdown')).toBeInTheDocument()
    expect(screen.getByText('Upcoming')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: /Open Door QR \/ Ticket/ })).toHaveAttribute('href', '/tickets/child-night-2')
  })

  it('toggles the expandable night schedule with aria-expanded and displays all status pills', async () => {
    const guamToday = new Date('2026-11-22T05:00:00Z')
    render(
      <MemoryRouter>
        <PassTicketCard ticket={baseParent} now={guamToday} />
      </MemoryRouter>,
    )

    const toggle = screen.getByRole('button', { name: 'All included nights (5)' })
    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByText('Storm Night')).not.toBeInTheDocument()

    const user = userEvent.setup()
    await user.click(toggle)
    expect(toggle).toHaveAttribute('aria-expanded', 'true')

    const list = screen.getByRole('list')
    const items = within(list).getAllByRole('listitem')
    expect(items).toHaveLength(5)

    expect(within(items[0]).getByText('Opening Night')).toBeInTheDocument()
    expect(within(items[0]).getByText('Checked In')).toBeInTheDocument()
    expect(within(items[0]).getByRole('link', { name: 'View Ticket for Opening Night' })).toHaveAttribute('href', '/tickets/child-night-1')

    expect(within(items[1]).getByText('Night 2 Showdown')).toBeInTheDocument()
    expect(within(items[1]).getByText('Tonight')).toBeInTheDocument()
    expect(within(items[1]).getByRole('link', { name: 'View Ticket for Night 2 Showdown' })).toHaveAttribute('href', '/tickets/child-night-2')

    expect(within(items[2]).getByText('Storm Night')).toBeInTheDocument()
    expect(within(items[2]).getByText('Postponed')).toBeInTheDocument()

    expect(within(items[3]).getByText('Cancelled Exhibition')).toBeInTheDocument()
    expect(within(items[3]).getByText('Cancelled')).toBeInTheDocument()
    expect(within(items[3]).queryByRole('link')).not.toBeInTheDocument()

    expect(within(items[4]).getByText('Finals Night')).toBeInTheDocument()
    expect(within(items[4]).getByText('Refund Pending')).toBeInTheDocument()

    await user.click(toggle)
    expect(toggle).toHaveAttribute('aria-expanded', 'false')
  })

  it('handles UTC vs Pacific/Guam midnight boundary accurately in spotlight and status helpers', () => {
    // 2026-11-21T16:00:00Z is ALREADY 2026-11-22 02:00 AM in Pacific/Guam (+10)!
    const guamEarlyMorning = new Date('2026-11-21T16:00:00Z')
    const result = selectSpotlightNight(baseParent.child_tickets, guamEarlyMorning)
    expect(result.kind).toBe('tonight')
    expect(result.ticket.id).toBe(102)
    expect(getChildNightStatus(baseParent.child_tickets[1], guamEarlyMorning).label).toBe('Tonight')
  })

  it('spotlights the most recent past non-cancelled night when all nights are in the past', () => {
    const afterAllNights = new Date('2026-12-01T00:00:00Z')
    render(
      <MemoryRouter>
        <PassTicketCard ticket={baseParent} now={afterAllNights} />
      </MemoryRouter>,
    )

    expect(screen.getByText('Latest Included Night')).toBeInTheDocument()
    expect(screen.getByText('Finals Night')).toBeInTheDocument()

    // When the final night is cancelled, falls back to the latest non-cancelled night before it
    const withoutFinals = {
      ...baseParent,
      child_tickets: baseParent.child_tickets.slice(0, 4),
    }
    const result = selectSpotlightNight(withoutFinals.child_tickets, afterAllNights)
    expect(result.kind).toBe('recent')
    expect(result.ticket.id).toBe(103)
  })

  it('distinguishes a cancelled or refund-pending pass with no child tickets from a newly issued pass', () => {
    const { rerender } = render(
      <MemoryRouter>
        <PassTicketCard ticket={{ ...baseParent, status: 'cancelled', child_tickets: [] }} />
      </MemoryRouter>,
    )
    expect(screen.getByText('This pass has been cancelled and its included nights are no longer valid.')).toBeInTheDocument()

    rerender(
      <MemoryRouter>
        <PassTicketCard ticket={{ ...baseParent, status: 'issued', refund_pending: true, child_tickets: [] }} />
      </MemoryRouter>,
    )
    expect(screen.getByText('This pass has been cancelled and its included nights are no longer valid.')).toBeInTheDocument()

    rerender(
      <MemoryRouter>
        <PassTicketCard ticket={{ ...baseParent, status: 'issued', child_tickets: [] }} />
      </MemoryRouter>,
    )
    expect(screen.getByText('Included night tickets will appear here once issued.')).toBeInTheDocument()
  })

  it('shows an actionable fallback message when a spotlight child ticket link is withheld', () => {
    const guamToday = new Date('2026-11-22T05:00:00Z')
    const withheldParent = {
      ...baseParent,
      child_tickets: baseParent.child_tickets.map(child => (
        child.id === 102
          ? { ...child, display_credential: null, display_token: null, ticket_url: null }
          : child
      )),
    }
    render(
      <MemoryRouter>
        <PassTicketCard ticket={withheldParent} now={guamToday} />
      </MemoryRouter>,
    )

    expect(screen.queryByRole('link', { name: /Open Door QR \/ Ticket/ })).not.toBeInTheDocument()
    expect(screen.getByText(/This night's ticket link is unavailable/i)).toBeInTheDocument()
  })
})
