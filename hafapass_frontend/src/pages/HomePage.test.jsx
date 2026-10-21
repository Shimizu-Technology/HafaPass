import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, fireEvent, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Link, MemoryRouter, Navigate, Route, Routes, useNavigate, useLocation } from 'react-router-dom'
import HomePage from './HomePage'
import apiClient from '../api/client'

const auth = vi.hoisted(() => ({ isLoaded: true, isSignedIn: false }))
vi.mock('../api/client', () => ({ default: { get: vi.fn() } }))
vi.mock('../components/SEO', () => ({ default: () => null }))
vi.mock('../components/ui/ScrollReveal', () => ({ FadeUp: ({ children }) => <div>{children}</div> }))
vi.mock('@clerk/clerk-react', () => ({
  useAuth: () => auth,
  SignIn: function MockSignIn({ signUpUrl, forceRedirectUrl }) {
    const navigate = useNavigate()
    if (auth.isSignedIn) return <Navigate to={forceRedirectUrl} replace />
    return <div><h1>Sign in to continue</h1><Link to={signUpUrl}>Create an account</Link>
      <button onClick={() => { auth.isSignedIn = true; navigate(forceRedirectUrl) }}>Complete sign in</button></div>
  },
  SignUp: function MockSignUp({ signInUrl, forceRedirectUrl }) {
    const navigate = useNavigate()
    if (auth.isSignedIn) return <Navigate to={forceRedirectUrl} replace />
    return <div><h1>Create an account</h1><Link to={signInUrl}>Use an existing account</Link>
      <button onClick={() => { auth.isSignedIn = true; navigate(forceRedirectUrl) }}>Complete signup</button></div>
  },
}))

let ProtectedRoute
let SignInPage
let SignUpPage
beforeAll(async () => {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_navigation_fixture')
  ;({ default: ProtectedRoute } = await import('../components/ProtectedRoute'))
  ;({ default: SignInPage } = await import('./SignInPage'))
  ;({ default: SignUpPage } = await import('./SignUpPage'))
})
afterAll(() => vi.unstubAllEnvs())

function BrowseDestination() {
  const location = useLocation()
  return <p>Browse destination {location.pathname}{location.search}</p>
}

function mount() {
  return render(<MemoryRouter initialEntries={['/']}><Routes>
    <Route path='/' element={<HomePage />} />
    <Route path='/events' element={<BrowseDestination />} />
    <Route path='/host' element={<h1>Host your event with HåfaPass</h1>} />
    <Route path='/dashboard' element={<ProtectedRoute><h1>Create your organizer profile</h1></ProtectedRoute>} />
    <Route path='/sign-in' element={<SignInPage />} />
    <Route path='/sign-up' element={<SignUpPage />} />
  </Routes></MemoryRouter>)
}

const entryLink = async entry => {
  await screen.findByRole('heading', { name: /No upcoming events listed/ })
  return entry === 'footer'
    ? screen.getByRole('link', { name: "For Organizers" })
    : screen.getAllByRole('link', { name: 'Start Hosting' })[entry === 'hero' ? 0 : 1]
}

describe('hosting entry navigation', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.get.mockReset()
    auth.isSignedIn = false
    apiClient.get.mockResolvedValue({ data: { events: [] } })
  })

  // The organizer journey (signup/sign-in return to setup) is covered by HostPage.test.jsx.
  it.each(['hero', 'bottom', 'footer'])('sends the %s hosting entry to the host landing page for every visitor', async entry => {
    for (const signedIn of [false, true]) {
      auth.isSignedIn = signedIn
      const view = mount()
      await userEvent.setup().click(await entryLink(entry))
      expect(await screen.findByRole('heading', { name: 'Host your event with HåfaPass' })).toBeInTheDocument()
      expect(screen.queryByRole('heading', { name: 'Sign in to continue' })).not.toBeInTheDocument()
      view.unmount()
    }
  })

  it('keeps event browsing separate while preserving the organizer call to action', async () => {
    apiClient.get.mockResolvedValue({ data: { events: [{ id: 37, slug: 'workshop', title: 'Workshop', starts_at: '2099-10-20T08:00:00Z', timezone: 'Pacific/Guam', ticket_types: [] }] } })
    mount()
    expect(await screen.findAllByRole('link', { name: 'Browse Events' }).then(links => links[0])).toHaveAttribute('href', '/events')
    screen.getAllByRole('link', { name: 'Start Hosting' }).forEach(link => expect(link).toHaveAttribute('href', '/host'))
    expect(screen.getByRole('link', { name: "Sign In" })).toHaveAttribute('href', '/sign-in')
  })

  it('keeps browsing available during a slow load without declaring the event list empty', async () => {
    let finish
    apiClient.get.mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
    mount()
    expect(screen.getByRole('status')).toHaveTextContent('Loading upcoming events')
    expect(screen.getAllByRole('link', { name: 'Browse Events' })[0]).toHaveAttribute('href', '/events')
    expect(screen.queryByText('Check back for new dates, or start setting up your own event.')).not.toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: /No upcoming events listed/ })).not.toBeInTheDocument()
    await act(async () => finish({ data: { events: [] } }))
    expect(await screen.findByText('Check back for new dates, or start setting up your own event.')).toBeInTheDocument()
    expect(screen.queryByRole('status')).not.toBeInTheDocument()
  })

  it('recovers a failed listing without presenting an outage as an empty event calendar', async () => {
    apiClient.get.mockRejectedValueOnce(new Error('Network unavailable'))
      .mockResolvedValueOnce({ data: { events: [{ id: 38, slug: 'recovered-event', title: 'Recovered event', starts_at: '2099-10-20T08:00:00Z', timezone: 'Pacific/Guam', ticket_types: [] }] } })
    mount()
    expect(await screen.findByRole('alert')).toHaveTextContent('Events couldn’t load')
    expect(screen.queryByText('Check back for new dates, or start setting up your own event.')).not.toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: /No upcoming events listed/ })).not.toBeInTheDocument()
    expect(screen.getAllByRole('link', { name: 'Browse Events' })[0]).toHaveAttribute('href', '/events')
    await userEvent.setup().click(screen.getByRole('button', { name: 'Retry events' }))
    expect(await screen.findByRole('link', { name: /Recovered event/ })).toHaveAttribute('href', '/events/recovered-event')
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(apiClient.get).toHaveBeenCalledTimes(2)
  })
  it('shows the available current tier with cents instead of the closed or sold-out cheap tickets', async () => {
    apiClient.get.mockResolvedValue({ data: { events: [{ id: 1, slug: 'tiered', title: 'Tiered event',
      starts_at: '2099-10-20T08:00:00Z', timezone: 'Pacific/Guam', ticket_types: [
        { price_cents: 0, quantity_remaining: 0 },
        { price_cents: 500, quantity_remaining: 10, on_sale: false },
        { price_cents: 2000, current_price_cents: 1250, quantity_remaining: 10, on_sale: true },
      ] }] } })
    mount()
    expect(await screen.findByText('From $12.50')).toBeInTheDocument()
    expect(screen.queryByText('From $20')).not.toBeInTheDocument()
  })

  it('carries event/venue search into native browse URL filters', async () => {
    mount()
    const user = userEvent.setup()
    await user.type(screen.getByRole('searchbox', { name: 'Event or venue' }), '  Music & food  ')
    await user.click(screen.getByRole('button', { name: 'Search' }))
    expect(await screen.findByText('Browse destination /events?search=Music+%26+food')).toBeInTheDocument()
  })

  it('renders only provided event artwork and preserves a compact featured event without artwork', async () => {
    apiClient.get.mockResolvedValue({ data: { events: [{ id: 44, slug: 'no-art', title: 'A real catalog event',
      is_featured: true, starts_at: '2099-10-20T08:00:00Z', timezone: 'Pacific/Guam', venue_name: 'Event venue', ticket_types: [] }] } })
    mount()
    const featured = await screen.findByRole('article', { name: 'Featured event' })
    expect(within(featured).getByRole('heading', { name: 'A real catalog event' })).toBeInTheDocument()
    expect(within(featured).getByRole('link', { name: 'Get Tickets' })).toHaveAttribute('href', '/events/no-art')
    expect(screen.queryByRole('img')).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Food & Drink' })).toHaveAttribute('href', '/events?category=dining')
    expect(screen.getByRole('link', { name: 'Classes & Workshops' })).toHaveAttribute('href', '/events?category=workshop')
  })

  it('recovers broken organizer artwork while keeping featured details and action usable', async () => {
    const artwork = 'https://storage.invalid/uploads/organizer-poster.png'
    apiClient.get.mockResolvedValue({ data: { events: [{ id: 45, slug: 'poster', title: 'Organizer poster event',
      cover_image_url: artwork, image_asset_host: 'storage.invalid', page_customization: { focal_point: { x: 25, y: 75 } },
      is_featured: true, starts_at: '2099-10-20T08:00:00Z', timezone: 'Pacific/Guam', ticket_types: [] }] } })
    mount()
    const featured = await screen.findByRole('article', { name: 'Featured event' })
    const image = within(featured).getByRole('img', { name: 'Artwork for Organizer poster event' })
    expect(image).toHaveAttribute('src', artwork)
    expect(image).toHaveAttribute('loading', 'eager')
    // Fills its 16:9 frame without relying on percentage heights; a blurred copy fills behind portrait posters.
    expect(image).toHaveClass('absolute', 'inset-0', 'object-contain')
    expect(image.style.objectPosition).toBe('')
    expect(image.parentElement).toHaveClass('relative', 'aspect-[16/9]')
    expect(within(featured).getByTestId('artwork-backdrop')).toHaveAttribute('src', artwork)
    expect(within(featured).getByTestId('artwork-backdrop')).toHaveStyle({ objectPosition: '25% 75%' })
    fireEvent.error(image)
    expect(within(featured).queryByRole('img')).not.toBeInTheDocument()
    expect(within(featured).getByText('Event artwork unavailable')).toBeInTheDocument()
    expect(within(featured).getByRole('link', { name: 'Get Tickets' })).toHaveAttribute('href', '/events/poster')
    expect(screen.getAllByRole('img').every(item => item.getAttribute('src') === artwork)).toBe(true)
  })

  it('groups event-local dates and sorts the listing without mutating the API array', async () => {
    const events = Object.freeze([
      { id: 46, slug: 'later', title: 'Later event', starts_at: '2099-10-21T08:00:00Z', timezone: 'Pacific/Guam', ticket_types: [] },
      { id: 47, slug: 'earlier', title: 'Earlier event', starts_at: '2099-10-20T08:00:00Z', timezone: 'Pacific/Guam', ticket_types: [] },
    ])
    apiClient.get.mockResolvedValue({ data: { events } })
    mount()
    await screen.findByRole('link', { name: /Earlier event/ })
    const rows = screen.getAllByRole('link').filter(link => /View event/.test(link.textContent))
    expect(rows.map(link => link.getAttribute('href'))).toEqual(['/events/earlier', '/events/later'])
    expect(events.map(event => event.id)).toEqual([46, 47])
    expect(screen.getByRole('region', { name: 'Events on Tuesday, Oct 20, 2099' })).toBeInTheDocument()
    expect(screen.getByRole('region', { name: 'Events on Wednesday, Oct 21, 2099' })).toBeInTheDocument()
  })

})
