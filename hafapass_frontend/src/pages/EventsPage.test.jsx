import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, useLocation, useNavigate } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import EventsPage from './EventsPage'
import apiClient from '../api/client'

vi.mock('../api/client', () => ({ default: { get: vi.fn() } }))
vi.mock('../components/SEO', () => ({ default: () => null }))
vi.mock('../components/EventCard', () => ({ default: ({ event }) => <p>{event.title}</p> }))
vi.mock('../components/ui/ScrollReveal', () => ({ StaggerContainer: ({ children }) => <div>{children}</div>, StaggerItem: ({ children }) => <div>{children}</div> }))
vi.mock('../hooks/useEventCategories', () => ({ default: () => [{ value: 'dining', label: 'Food & Drink' }, { value: 'concert', label: 'Music & Concerts' }] }))
function OpenNextEvent() { const navigate = useNavigate(); return <button onClick={() => navigate('/events/next?waitlist_offer=protected-fixture')}>Open next event</button> }
function Location() { return <output aria-label="Browse URL">{useLocation().search}</output> }
const mount = path => render(<MemoryRouter initialEntries={[path || '/events']}><EventsPage /><Location /><OpenNextEvent /></MemoryRouter>)
const result = (page = 1) => ({ data: { events: [{ id: page, title: `Event page ${page}` }], meta: { current_page: page, total_pages: 3, total_count: 30, prev_page: page > 1 ? page - 1 : null, next_page: page < 3 ? page + 1 : null } } })
beforeEach(() => { vi.clearAllMocks(); apiClient.get.mockImplementation((_url, { params }) => Promise.resolve(result(params.page))) })

describe('event guide filters and recovery', () => {
  it('hydrates native controls and requests from URL filters', async () => {
    mount('/events?search=music&category=dining&date=tonight&price=free&village=Hag%C3%A5t%C3%B1a&page=3')
    expect(await screen.findByText('Event page 3')).toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'Search events and venues' })).toHaveValue('music')
    expect(screen.getByRole('combobox', { name: 'Category' })).toHaveValue('dining')
    expect(screen.getByRole('combobox', { name: 'When' })).toHaveValue('tonight')
    expect(screen.getByRole('combobox', { name: 'Price' })).toHaveValue('free')
    expect(screen.getByRole('combobox', { name: 'Village' })).toHaveValue('Hagåtña')
    expect(apiClient.get).toHaveBeenLastCalledWith('/events', { params: { page: 3, per_page: 12, q: 'music', category: 'dining', window: 'tonight', price: 'free', village: 'Hagåtña' } })
  })

  it('resets search pagination while retaining the other native filters', async () => {
    mount('/events?category=dining&price=free&page=3')
    await screen.findByText('Event page 3')
    await userEvent.type(screen.getByRole('textbox', { name: 'Search events and venues' }), 'new')
    await screen.findByText('Event page 1')
    expect(apiClient.get).toHaveBeenLastCalledWith('/events', { params: { page: 1, per_page: 12, q: 'new', category: 'dining', price: 'free' } })
    expect(screen.getByLabelText('Browse URL')).toHaveTextContent('search=new&category=dining&price=free')
    expect(screen.getByLabelText('Browse URL')).not.toHaveTextContent('page=')
  })

  it('keeps an outage distinct from empty results and retries the saved filters', async () => {
    apiClient.get.mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce(result())
    mount('/events?category=dining&price=free')
    expect(await screen.findByRole('alert')).toHaveTextContent('Your filters are saved')
    expect(screen.queryByRole('heading', { name: 'No events yet' })).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Try again' }))
    await screen.findByText('Event page 1')
    expect(apiClient.get.mock.calls[0][1]).toEqual(apiClient.get.mock.calls[1][1])
    expect(screen.getByRole('combobox', { name: 'Price' })).toHaveValue('free')
  })

  it('clears no-match filters and retains organizer entry via the protected dashboard', async () => {
    apiClient.get.mockResolvedValue({ data: { events: [], meta: { current_page: 1, total_pages: 1, total_count: 0 } } })
    mount('/events?search=nothing&category=dining&date=tonight&price=free&village=Hag%C3%A5t%C3%B1a')
    await screen.findByRole('heading', { name: 'No matching events' })
    await userEvent.click(screen.getByRole('button', { name: 'Clear filters' }))
    await screen.findByRole('heading', { name: 'No events yet' })
    await waitFor(() => expect(screen.getByLabelText('Browse URL')).toHaveTextContent(/^$/))
    expect(screen.getByRole('link', { name: 'Create an Event' })).toHaveAttribute('href', '/dashboard')
    expect(screen.getByRole('link', { name: 'For event organizers' })).toHaveAttribute('href', '/dashboard')
  })
  it('does not overwrite the next event’s offer URL while the listing outlet is retained', async () => {
    mount('/events?search=music&price=free')
    await screen.findByText('Event page 1')
    await userEvent.click(screen.getByRole('button', { name: 'Open next event' }))
    await waitFor(() => expect(screen.getByLabelText('Browse URL')).toHaveTextContent('?waitlist_offer=protected-fixture'))
    expect(screen.getByLabelText('Browse URL')).not.toHaveTextContent('search=')
    expect(screen.queryByRole('textbox', { name: 'Search events and venues' })).not.toBeInTheDocument()
  })

})
