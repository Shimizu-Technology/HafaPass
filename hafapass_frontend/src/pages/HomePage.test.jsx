import { act, fireEvent, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import HomePage from './HomePage'
import apiClient from '../api/client'
vi.mock('../api/client', () => ({ default: { get: vi.fn() } }))
vi.mock('../components/SEO', () => ({ default: () => null }))
const event = { id: 37, slug: 'community-night', title: 'Community night', starts_at: '2099-10-20T08:00:00Z', timezone: 'Pacific/Guam', venue_city: 'Hagåtña', ticket_types: [] }
function Destination() { const location = useLocation(); return <p>Browse destination {location.pathname}{location.search}</p> }
function mount() { return render(<MemoryRouter><Routes><Route path="/" element={<HomePage />} /><Route path="/events" element={<Destination />} /><Route path="/events/:slug" element={<Destination />} /><Route path="/host" element={<h1>Host your event</h1>} /></Routes></MemoryRouter>) }
const pointer = coarse => vi.stubGlobal('matchMedia', vi.fn(query => ({ matches: coarse && query === '(pointer: coarse)', addEventListener: vi.fn(), removeEventListener: vi.fn() })))
beforeEach(() => { apiClient.get.mockReset(); apiClient.get.mockResolvedValue({ data: { events: [] } }) })
afterEach(() => { vi.unstubAllGlobals() })

describe('the public ticket', () => {
  it('keeps empty inventory honest with only the HåfaPass default hero card and no search or categories', async () => {
    mount()
    await screen.findByRole('heading', { name: 'The first events are on their way.' })
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('Your night out on Guam starts here.')
    expect(screen.getByText('When organizers publish, you’ll find them here. Buy in a minute and keep your tickets on your phone.')).toBeInTheDocument()
    const deck = screen.getByTestId('hero-fanned-deck')
    expect(deck).toHaveAttribute('data-card-count', '1')
    expect(screen.queryByTestId('hero-deck-controls')).not.toBeInTheDocument()
    expect(screen.queryByText(/soon/i)).not.toBeInTheDocument()
    expect(screen.queryByRole('search')).not.toBeInTheDocument()
    expect(screen.queryByRole('combobox')).not.toBeInTheDocument()
    expect(screen.queryByRole('img')).not.toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'Coming up on Guam' })).not.toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: /Explore by category/i })).not.toBeInTheDocument()
    const footer = screen.getByRole('contentinfo')
    for (const policy of ['privacy', 'buyer-terms', 'refunds', 'organizer-agreement', 'accessibility', 'cookies']) {
      expect(footer.querySelector(`a[href="/policies/${policy}"]`)).toBeInTheDocument()
    }
  })

  it('gives phone buyers an install action, order recovery and how the pass works, and pitches hosting once', async () => {
    pointer(true)
    const { container } = mount()
    await screen.findByRole('heading', { name: 'The first events are on their way.' })
    await userEvent.setup().click(screen.getByText('Add to Home Screen', { selector: 'summary' }))
    expect(screen.getByText(/On iPhone or iPad, open HåfaPass in Safari/)).toBeVisible()
    expect(screen.getByRole('link', { name: 'Already bought a ticket? Find it' })).toHaveAttribute('href', '/orders/recover')
    const steps = screen.getByRole('region', { name: 'How your pass works' })
    expect(within(steps).getAllByRole('listitem').map(item => item.textContent)).toEqual([
      'Find an eventEverything on Guam, in Guam time.',
      'Buy in a minutePay by card. Your tickets arrive by email, no account needed.',
      'Walk right inShow the QR on your phone at the door.',
    ].map((text, index) => `${index + 1}${text}`))
    expect(screen.getAllByRole('link', { name: /hosting|sell tickets/i }).map(link => link.getAttribute('href'))).toEqual(['/host'])
    expect(container.querySelector('.planning-ticket .btn-primary')).not.toBeInTheDocument()
  })

  it('opens the browser installer directly from the empty Home when one was offered', async () => {
    const { initializeInstallationOffers } = await import('../utils/installationOffers')
    const stop = initializeInstallationOffers()
    const offer = new Event('beforeinstallprompt', { cancelable: true })
    const prompt = vi.fn().mockResolvedValue(undefined)
    Object.assign(offer, { prompt, userChoice: Promise.resolve({ outcome: 'accepted' }) })
    fireEvent(window, offer)
    mount()
    await userEvent.setup().click(await screen.findByRole('button', { name: 'Install HåfaPass' }))
    expect(prompt).toHaveBeenCalledOnce()
    stop()
  })

  it('keeps one order-recovery link and removes the empty-inventory steps once events load', async () => {
    apiClient.get.mockResolvedValue({ data: { events: [event] } })
    mount()
    await screen.findByRole('list', { name: 'Coming up on Guam' })
    expect(screen.getAllByRole('link', { name: 'Already bought a ticket? Find it' })).toHaveLength(1)
    expect(screen.queryByRole('region', { name: 'How your pass works' })).not.toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Planning an event?' })).toBeInTheDocument()
  })

  it.each(['Start hosting', 'For organizers'])('opens hosting from %s', async name => {
    mount()
    await screen.findByText('The first events are on their way.')
    await userEvent.setup().click(screen.getByRole('link', { name, exact: true }))
    expect(screen.getByRole('heading', { name: 'Host your event' })).toBeInTheDocument()
  })

  it('keeps the HåfaPass default pass and footer usable while inventory is pending', async () => {
    let finish
    apiClient.get.mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
    mount()
    expect(screen.getByText('Loading upcoming events…')).toBeInTheDocument()
    expect(screen.getByTestId('hero-brand-card')).toBeInTheDocument()
    expect(screen.getAllByRole('link', { name: 'Browse events' })[0]).toHaveAttribute('href', '/events')
    const footer = screen.getByRole('contentinfo')
    for (const policy of ['privacy', 'buyer-terms', 'refunds', 'organizer-agreement', 'accessibility', 'cookies']) {
      expect(footer.querySelector(`a[href="/policies/${policy}"]`)).toBeInTheDocument()
    }
    await act(async () => finish({ data: { events: [] } }))
    expect(screen.queryByRole('status')).not.toBeInTheDocument()
    expect(screen.queryByRole('search')).not.toBeInTheDocument()
  })

  it('recovers an outage without declaring inventory empty', async () => {
    apiClient.get.mockRejectedValueOnce(Error('offline')).mockResolvedValueOnce({ data: { events: [event] } })
    mount()
    expect(await screen.findByRole('alert')).toHaveTextContent('Events couldn’t load')
    expect(screen.queryByText('The first events are on their way.')).not.toBeInTheDocument()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Retry events' }))
    expect(within(await screen.findByRole('list', { name: 'Coming up on Guam' })).getByRole('link', { name: /Community night/ })).toHaveAttribute('href', '/events/community-night')
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('carries all working controls into the Events query contract', async () => {
    apiClient.get.mockResolvedValue({ data: { events: [event] } })
    mount()
    const user = userEvent.setup()
    await user.type(await screen.findByRole('searchbox', { name: 'Event or venue' }), '  Music & food  ')
    await user.selectOptions(screen.getByLabelText('When'), 'weekend')
    await user.selectOptions(screen.getByLabelText('Where'), 'Hagåtña')
    await user.click(screen.getByRole('button', { name: 'Search' }))
    expect(screen.getByText('Browse destination /events?search=Music+%26+food&date=weekend&village=Hag%C3%A5t%C3%B1a')).toBeInTheDocument()
  })

  it('uses current purchasable all-in prices and included fees on the cards', async () => {
    apiClient.get.mockResolvedValue({
      data: {
        events: [{
          ...event,
          ticket_types: [
            { price_cents: 0, quantity_remaining: 0 },
            { price_cents: 2500, all_in_price_cents: 2725, service_fee_cents: 225, quantity_remaining: 20, on_sale: true },
          ],
        }],
      },
    })
    mount()
    const row = await screen.findByRole('list', { name: 'Coming up on Guam' })
    expect(within(row).getByText('From $27.25')).toBeInTheDocument()
    expect(within(row).getByText('Includes $2.25 service fee')).toBeInTheDocument()
  })

  it('folds featured events into one row and sorts without mutating the API array', async () => {
    const events = Object.freeze([
      { ...event, id: 38, slug: 'later', title: 'Later featured event', is_featured: true, starts_at: '2099-10-21T08:00:00Z' },
      event,
    ])
    apiClient.get.mockResolvedValue({ data: { events } })
    mount()
    const row = await screen.findByRole('list', { name: 'Coming up on Guam' })
    expect(within(row).getAllByRole('link').map(a => a.getAttribute('href'))).toEqual(['/events/later', '/events/community-night'])
    expect(events.map(e => e.id)).toEqual([38, 37])
    expect(screen.getByRole('link', { name: 'Food & Drink' })).toHaveAttribute('href', '/events?category=dining')
  })

  it('falls back to the date tile when organizer artwork fails', async () => {
    apiClient.get.mockResolvedValue({
      data: { events: [{ ...event, image_asset_host: 'art.example.test', cover_image_url: 'https://art.example.test/uploads/poster.jpg' }] },
    })
    mount()
    fireEvent.error(await screen.findByRole('img', { name: event.title }))
    expect(screen.queryByRole('img', { name: event.title })).not.toBeInTheDocument()
    expect(screen.getByLabelText('Tuesday, Oct 20, 2099')).toBeInTheDocument()
  })
})

describe('discovery first — Mockup E flow', () => {
  it('renders a single-block headline with no word-splitting spans and leads the hero deck with HåfaPass', async () => {
    apiClient.get.mockResolvedValue({ data: { events: [event] } })
    mount()
    await screen.findByRole('list', { name: 'Coming up on Guam' })
    const heading = screen.getByRole('heading', { level: 1, name: 'Your night out on Guam starts here.' })
    expect(heading.querySelectorAll('.hero-rise-word')).toHaveLength(0)
    const deck = screen.getByTestId('hero-fanned-deck')
    expect(deck).toHaveAttribute('data-card-count', '2')
    expect(deck.querySelector('[data-front="true"]')).toHaveAttribute('data-card-kind', 'brand')
    expect(screen.queryByTestId('event-stub-deck')).not.toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'Featured on Guam' })).not.toBeInTheDocument()
  })

  it('filters the Coming up on Guam carousel in place using one-tap quick filter chips', async () => {
    apiClient.get.mockResolvedValue({
      data: {
        events: [
          { ...event, id: 40, slug: 'hagatna-night', title: 'Hagåtña Night', venue_city: 'Hagåtña' },
          { ...event, id: 41, slug: 'dededo-a', title: 'Dededo One', venue_city: 'Dededo' },
          { ...event, id: 42, slug: 'dededo-b', title: 'Dededo Two', venue_city: 'Dededo' },
        ],
      },
    })
    mount()
    const user = userEvent.setup()
    const filterGroup = await screen.findByRole('group', { name: 'Quick filters' })
    const buttons = within(filterGroup).getAllByRole('button')
    expect(buttons.map(btn => btn.textContent)).toEqual(['All upcoming', 'Tonight', 'This weekend', 'Dededo', 'Hagåtña'])

    await user.click(within(filterGroup).getByRole('button', { name: 'Dededo' }))
    const row = screen.getByRole('list', { name: 'Coming up on Guam' })
    expect(within(row).getAllByRole('link').map(a => a.getAttribute('href'))).toEqual(['/events/dededo-a', '/events/dededo-b'])

    // Clicking the active filter again returns to All upcoming.
    await user.click(within(filterGroup).getByRole('button', { name: 'Dededo' }))
    expect(within(screen.getByRole('list', { name: 'Coming up on Guam' })).getAllByRole('link')).toHaveLength(3)
  })

  it('opens the date and village choices from a labeled 48px button on phones', async () => {
    apiClient.get.mockResolvedValue({ data: { events: [event] } })
    mount()
    const toggle = await screen.findByRole('button', { name: 'Choose a date or village' })
    expect(toggle).toHaveClass('min-h-12', 'sm:hidden')
    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    const filters = document.getElementById(toggle.getAttribute('aria-controls'))
    expect(filters).toHaveClass('hidden', 'sm:grid')
    await userEvent.setup().click(toggle)
    expect(toggle).toHaveAttribute('aria-expanded', 'true')
    expect(filters).toHaveClass('grid')
    expect(filters).not.toHaveClass('hidden')
  })

  it('tells the ticket story finished and still before motion is allowed', async () => {
    apiClient.get.mockResolvedValue({ data: { events: [event] } })
    mount()
    const story = await screen.findByRole('region', { name: 'From your phone to the door' })
    expect(within(story).getAllByRole('heading', { level: 3 }).map(item => item.textContent)).toEqual(['Pick your night', 'Instant QR pass', 'Fast scan at the door'])
    expect(story).toHaveTextContent('Community night')
  })
})
