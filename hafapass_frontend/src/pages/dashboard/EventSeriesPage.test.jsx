import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import { resetOrganizerOrganizations } from '../../utils/organizerOrganizations'
import EventSeriesPage from './EventSeriesPage'

function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/dashboard/series']}>
      <EventSeriesPage />
    </MemoryRouter>
  )
}

describe('EventSeriesPage', () => {
  const managerOrg = {
    id: 1,
    name: 'FD Alumni Association',
    permissions: { view_events: true, manage_events: true },
  }

  const readOnlyOrg = {
    id: 1,
    name: 'FD Alumni Association',
    permissions: { view_events: true, view_finance: true, manage_events: false },
  }

  const scannerOrg = {
    id: 1,
    name: 'FD Alumni Association',
    permissions: { view_events: true, scan: true },
  }

  const initialSeries = [
    {
      id: 10,
      name: 'FD Tourney 2026',
      slug: 'fd-tourney-2026',
      description: 'Annual alumni basketball tournament',
      status: 'active',
      events_count: 2,
      events: [
        {
          id: 101,
          event_id: 101,
          role: 'regular_night',
          position: 0,
          title: 'Night 1 - Pool Play',
          status: 'published',
          starts_at: '2026-12-01T08:00:00Z',
          timezone: 'Pacific/Guam',
          venue_name: 'FD Phoenix Center',
        },
        {
          id: 102,
          event_id: 102,
          role: 'championship_night',
          position: 1,
          title: 'Championship Night',
          status: 'draft',
          starts_at: '2026-12-05T08:00:00Z',
          timezone: 'Pacific/Guam',
          venue_name: 'FD Phoenix Center',
        },
      ],
    },
  ]

  const orgEvents = [
    { id: 101, title: 'Night 1 - Pool Play' },
    { id: 102, title: 'Championship Night' },
    { id: 103, title: 'Tournament Season Pass' },
  ]

  beforeEach(() => {
    resetOrganizerOrganizations()
    window.localStorage.clear()
    vi.restoreAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('lists series and groups member events by role', async () => {
    vi.spyOn(apiClient, 'get').mockImplementation((url) => {
      if (url === '/organizer/organizations') return Promise.resolve({ data: [managerOrg] })
      if (url === '/organizer/event_series') return Promise.resolve({ data: { event_series: initialSeries } })
      if (url.startsWith('/organizer/events')) return Promise.resolve({ data: { events: orgEvents } })
      return Promise.reject(new Error(`Unexpected GET ${url}`))
    })

    renderPage()

    expect(await screen.findByRole('heading', { name: 'FD Tourney 2026' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Regular Nights' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Championship Nights' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Night 1 - Pool Play' })).toHaveAttribute('href', '/dashboard/events/101')
    expect(screen.getByRole('link', { name: 'Championship Night' })).toHaveAttribute('href', '/dashboard/events/102')
  })

  it('creates a series, adds an event, removes an event, and bulk clones nights', async () => {
    const user = userEvent.setup()
    let currentSeries = structuredClone(initialSeries)

    vi.spyOn(apiClient, 'get').mockImplementation((url) => {
      if (url === '/organizer/organizations') return Promise.resolve({ data: [managerOrg] })
      if (url === '/organizer/event_series') return Promise.resolve({ data: { event_series: currentSeries } })
      if (url.startsWith('/organizer/events')) return Promise.resolve({ data: { events: orgEvents } })
      return Promise.reject(new Error(`Unexpected GET ${url}`))
    })

    const postSpy = vi.spyOn(apiClient, 'post').mockImplementation((url, payload) => {
      if (url === '/organizer/event_series') {
        const created = {
          id: 20,
          name: payload.name,
          slug: 'summer-league-2026',
          description: payload.description,
          status: payload.status,
          events_count: 0,
          events: [],
        }
        currentSeries = [created, ...currentSeries]
        return Promise.resolve({ data: created })
      }
      if (url === '/organizer/event_series/10/events') {
        const updated = {
          ...currentSeries.find((s) => s.id === 10),
          events_count: 3,
          events: [
            ...currentSeries.find((s) => s.id === 10).events,
            {
              id: 103,
              event_id: 103,
              role: payload.role,
              position: 2,
              title: 'Tournament Season Pass',
              status: 'draft',
              timezone: 'Pacific/Guam',
            },
          ],
        }
        currentSeries = currentSeries.map((s) => (s.id === 10 ? updated : s))
        return Promise.resolve({ data: updated })
      }
      if (url === '/organizer/events/101/bulk_clone') {
        return Promise.resolve({
          data: {
            created_count: payload.occurrences.length,
            events: payload.occurrences.map((o, idx) => ({ id: 200 + idx, title: o.title })),
          },
        })
      }
      return Promise.reject(new Error(`Unexpected POST ${url}`))
    })

    const deleteSpy = vi.spyOn(apiClient, 'delete').mockResolvedValue({ data: null })

    renderPage()
    expect(await screen.findByRole('heading', { name: 'FD Tourney 2026' })).toBeInTheDocument()

    // Add existing event
    await user.selectOptions(screen.getByLabelText('Select event'), '103')
    await user.selectOptions(screen.getByLabelText('Role'), 'pass_sale')
    await user.click(screen.getByRole('button', { name: 'Add' }))
    expect(await screen.findByRole('link', { name: 'Tournament Season Pass' })).toBeInTheDocument()

    // Bulk clone nights
    await user.click(screen.getByRole('button', { name: 'Bulk clone nights' }))
    const dialog = screen.getByRole('dialog')
    await user.type(within(dialog).getByLabelText(/Title/), 'Night 2 - Pool Play')
    await user.type(within(dialog).getByLabelText(/Starts at/), '2026-12-02T18:00')
    await user.type(within(dialog).getByLabelText(/Ends at/), '2026-12-02T22:00')
    await user.click(within(dialog).getByRole('button', { name: /Create 1 night/ }))

    await waitFor(() => {
      expect(postSpy).toHaveBeenCalledWith(
        '/organizer/events/101/bulk_clone',
        expect.objectContaining({
          event_series_id: 10,
          series_role: 'regular_night',
          occurrences: [
            expect.objectContaining({
              title: 'Night 2 - Pool Play',
              starts_at: '2026-12-02T18:00',
              ends_at: '2026-12-02T22:00',
            }),
          ],
        }),
        expect.any(Object)
      )
    })
    expect(await screen.findByRole('status')).toHaveTextContent('Created 1 night')

    // Remove an event
    const removeButtons = screen.getAllByRole('button', { name: 'Remove' })
    await user.click(removeButtons[0])
    await waitFor(() => {
      expect(deleteSpy).toHaveBeenCalledWith('/organizer/event_series/10/events/101', expect.any(Object))
    })

    // Create a new series
    await user.click(screen.getByRole('button', { name: 'New series' }))
    const createDialog = screen.getByRole('dialog')
    await user.type(within(createDialog).getByLabelText(/Series name/), 'Summer League 2026')
    await user.click(within(createDialog).getByRole('button', { name: 'Create series' }))
    expect(await screen.findByRole('heading', { name: 'Summer League 2026' })).toBeInTheDocument()
  })

  it('hides mutation controls for read-only finance members', async () => {
    vi.spyOn(apiClient, 'get').mockImplementation((url) => {
      if (url === '/organizer/organizations') return Promise.resolve({ data: [readOnlyOrg] })
      if (url === '/organizer/event_series') return Promise.resolve({ data: { event_series: initialSeries } })
      if (url.startsWith('/organizer/events')) return Promise.resolve({ data: { events: orgEvents } })
      return Promise.reject(new Error(`Unexpected GET ${url}`))
    })

    renderPage()

    expect(await screen.findByRole('heading', { name: 'FD Tourney 2026' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'New series' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Bulk clone nights' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Remove' })).not.toBeInTheDocument()
  })

  it('denies access to assignment-scoped scanner staff without fetching event series', async () => {
    const getSpy = vi.spyOn(apiClient, 'get').mockImplementation((url) => {
      if (url === '/organizer/organizations') return Promise.resolve({ data: [scannerOrg] })
      return Promise.reject(new Error(`Unexpected GET ${url}`))
    })

    renderPage()

    expect(await screen.findByText('You don’t have access to event series')).toBeInTheDocument()
    expect(getSpy).toHaveBeenCalledTimes(1)
    expect(getSpy).toHaveBeenCalledWith('/organizer/organizations', expect.any(Object))
  })

  it('requires confirmation before archiving or deleting a series', async () => {
    const user = userEvent.setup()
    const emptySeries = [
      {
        id: 30,
        name: 'Empty Draft Series',
        slug: 'empty-draft-series',
        description: '',
        status: 'draft',
        events_count: 0,
        events: [],
      },
      ...initialSeries,
    ]

    vi.spyOn(apiClient, 'get').mockImplementation((url) => {
      if (url === '/organizer/organizations') return Promise.resolve({ data: [managerOrg] })
      if (url === '/organizer/event_series') return Promise.resolve({ data: { event_series: emptySeries } })
      if (url.startsWith('/organizer/events')) return Promise.resolve({ data: { events: orgEvents } })
      return Promise.reject(new Error(`Unexpected GET ${url}`))
    })

    const patchSpy = vi.spyOn(apiClient, 'patch').mockResolvedValue({
      data: { ...emptySeries[0], status: 'archived' },
    })
    const deleteSpy = vi.spyOn(apiClient, 'delete').mockResolvedValue({ data: null })

    renderPage()
    expect(await screen.findByRole('heading', { name: 'Empty Draft Series' })).toBeInTheDocument()

    // Archive requires confirmation; cancel does not mutate
    await user.click(screen.getByRole('button', { name: 'Archive' }))
    const archiveDialog = screen.getByRole('dialog')
    expect(within(archiveDialog).getByRole('heading', { name: 'Archive event series?' })).toBeInTheDocument()
    expect(patchSpy).not.toHaveBeenCalled()
    await user.click(within(archiveDialog).getByRole('button', { name: 'Cancel' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(patchSpy).not.toHaveBeenCalled()

    // Confirm archive
    await user.click(screen.getByRole('button', { name: 'Archive' }))
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Archive series' }))
    await waitFor(() => {
      expect(patchSpy).toHaveBeenCalledWith('/organizer/event_series/30', { status: 'archived' }, expect.any(Object))
    })
    expect(await screen.findByRole('status')).toHaveTextContent('Archived "Empty Draft Series".')

    // Delete requires confirmation; cancel does not mutate
    await user.click(screen.getByRole('button', { name: 'Delete' }))
    const deleteDialog = screen.getByRole('dialog')
    expect(within(deleteDialog).getByRole('heading', { name: 'Delete event series?' })).toBeInTheDocument()
    expect(deleteSpy).not.toHaveBeenCalled()
    await user.click(within(deleteDialog).getByRole('button', { name: 'Cancel' }))
    expect(deleteSpy).not.toHaveBeenCalled()

    // Confirm delete selects the next remaining series
    await user.click(screen.getByRole('button', { name: 'Delete' }))
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Delete series' }))
    await waitFor(() => {
      expect(deleteSpy).toHaveBeenCalledWith('/organizer/event_series/30', expect.any(Object))
    })
    expect(await screen.findByRole('status')).toHaveTextContent('Deleted "Empty Draft Series".')
    expect(screen.getByRole('heading', { name: 'FD Tourney 2026' })).toBeInTheDocument()
  })
})
