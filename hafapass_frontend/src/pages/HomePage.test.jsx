import { act, fireEvent, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import HomePage from './HomePage'
import apiClient from '../api/client'
vi.mock('../api/client', () => ({ default: { get: vi.fn() } }))
vi.mock('../components/SEO', () => ({ default: () => null }))
const event = { id: 37, slug: 'community-night', title: 'Community night', starts_at: '2099-10-20T08:00:00Z', timezone: 'Pacific/Guam', ticket_types: [] }
function Destination() { const location = useLocation(); return <p>Browse destination {location.pathname}{location.search}</p> }
function mount() { return render(<MemoryRouter><Routes><Route path="/" element={<HomePage />} /><Route path="/events" element={<Destination />} /><Route path="/host" element={<h1>Host your event</h1>} /></Routes></MemoryRouter>) }
beforeEach(() => { apiClient.get.mockReset(); apiClient.get.mockResolvedValue({data:{events:[]}}) })
describe('the public ticket', () => {
 it('keeps empty inventory honest with no search, category links or borrowed photos', async () => {
  mount()
  await screen.findByRole('heading', {name:'The first events are on their way.'})
  expect(screen.getByRole('heading', {level:1})).toHaveTextContent('Your night out on Guam starts here.')
  expect(screen.getByText('When organizers publish, you’ll find them here. Buy in a minute and keep your tickets on your phone.')).toBeInTheDocument()
  expect(screen.queryByText(/soon/i)).not.toBeInTheDocument()
  expect(screen.queryByRole('search')).not.toBeInTheDocument()
  expect(screen.queryByRole('combobox')).not.toBeInTheDocument()
  expect(screen.queryByRole('img')).not.toBeInTheDocument()
  expect(screen.queryByRole('heading', {name:'Coming up'})).not.toBeInTheDocument()
  expect(screen.queryByRole('heading', {name:/Explore by category/i})).not.toBeInTheDocument()
  const footer=screen.getByRole('contentinfo')
  for(const policy of ['privacy','buyer-terms','refunds','organizer-agreement','accessibility','cookies']) expect(footer.querySelector(`a[href="/policies/${policy}"]`)).toBeInTheDocument()
 })
 it('gives buyers an install action, order recovery and how the pass works, and pitches hosting once', async () => {
  const {container}=mount()
  await screen.findByRole('heading', {name:'The first events are on their way.'})
  const hero=container.querySelector('.hero-ticket')
  await userEvent.setup().click(within(hero).getByText('Add to Home Screen'))
  expect(within(hero).getByText(/On iPhone or iPad, open HåfaPass in Safari/)).toBeVisible()
  expect(within(hero).getByRole('link',{name:'Already bought a ticket? Find it'})).toHaveAttribute('href','/orders/recover')
  expect(within(hero).queryByRole('link',{name:'Sell tickets'})).not.toBeInTheDocument()
  const steps=screen.getByRole('region',{name:'How your pass works'})
  expect(within(steps).getAllByRole('listitem').map(item=>item.textContent)).toEqual([
   'Find an eventEverything on Guam, in Guam time.',
   'Buy in a minutePay by card. Your tickets arrive by email, no account needed.',
   'Walk right inShow the QR on your phone at the door.',
  ].map((text,index)=>`${index+1}${text}`))
  expect(screen.getAllByRole('link',{name:/hosting|sell tickets/i}).map(link=>link.getAttribute('href'))).toEqual(['/host'])
  expect(container.querySelector('.planning-ticket .btn-primary')).not.toBeInTheDocument()
 })
 it('opens the browser installer directly from the empty Home when one was offered', async () => {
  const {initializeInstallationOffers}=await import('../utils/installationOffers')
  const stop=initializeInstallationOffers()
  const offer=new Event('beforeinstallprompt',{cancelable:true})
  const prompt=vi.fn().mockResolvedValue(undefined)
  Object.assign(offer,{prompt,userChoice:Promise.resolve({outcome:'accepted'})})
  fireEvent(window,offer)
  mount()
  await userEvent.setup().click(await screen.findByRole('button',{name:'Add to Home Screen'}))
  expect(prompt).toHaveBeenCalledOnce()
  stop()
 })
 it('drops the hero hosting stub and keeps order recovery once events load', async () => {
  apiClient.get.mockResolvedValue({data:{events:[event]}})
  const {container}=mount()
  await screen.findByRole('list',{name:'Coming up'})
  const hero=container.querySelector('.hero-ticket')
  expect(within(hero).queryByRole('link',{name:'Sell tickets'})).not.toBeInTheDocument()
  expect(within(hero).getByRole('link',{name:'Already bought a ticket? Find it'})).toHaveAttribute('href','/orders/recover')
  expect(screen.queryByRole('region',{name:'How your pass works'})).not.toBeInTheDocument()
  expect(screen.getByRole('heading',{name:'Planning an event?'})).toBeInTheDocument()
 })
 it.each(['Start Hosting','For Organizers'])('opens hosting from %s', async name => {
  mount(); await screen.findByText('The first events are on their way.')
  await userEvent.setup().click(screen.getByRole('link',{name,exact:true}))
  expect(screen.getByRole('heading',{name:'Host your event'})).toBeInTheDocument()
 })
 it('keeps the ticket, hosting and footer usable while inventory is pending', async () => {
  let finish; apiClient.get.mockImplementationOnce(()=>new Promise(resolve=>{finish=resolve}))
  const {container}=mount()
  expect(screen.getByText('Loading upcoming events…')).toBeInTheDocument()
  expect(screen.getAllByRole('link',{name:'Browse Events'})[0]).toHaveAttribute('href','/events')
  const ticket=container.querySelector('.hero-ticket')
  const footer=screen.getByRole('contentinfo')
  for(const policy of ['privacy','buyer-terms','refunds','organizer-agreement','accessibility','cookies']) expect(footer.querySelector(`a[href="/policies/${policy}"]`)).toBeInTheDocument()
  expect(screen.getByRole('link',{name:'Sell tickets'})).toHaveAttribute('href','/host')
  await act(async()=>finish({data:{events:[]}}))
  expect(container.querySelector('.hero-ticket')).toBe(ticket)
  expect(screen.queryByRole('status')).not.toBeInTheDocument()
  expect(screen.queryByRole('search')).not.toBeInTheDocument()
 })
 it('recovers an outage without declaring inventory empty', async () => {
  apiClient.get.mockRejectedValueOnce(Error('offline')).mockResolvedValueOnce({data:{events:[event]}})
  mount(); expect(await screen.findByRole('alert')).toHaveTextContent('Events couldn’t load')
  expect(screen.queryByText('The first events are on their way.')).not.toBeInTheDocument()
  await userEvent.setup().click(screen.getByRole('button',{name:'Retry events'}))
  expect(await screen.findByRole('link',{name:/Community night/})).toHaveAttribute('href','/events/community-night')
  expect(screen.queryByRole('alert')).not.toBeInTheDocument()
 })
 it('carries all working controls into the Events query contract', async () => {
  apiClient.get.mockResolvedValue({data:{events:[event]}}); mount(); const user=userEvent.setup()
  await user.type(await screen.findByRole('searchbox',{name:'Event or venue'}),'  Music & food  ')
  await user.selectOptions(screen.getByLabelText('When'),'weekend')
  await user.selectOptions(screen.getByLabelText('Where'),'Hagåtña')
  await user.click(screen.getByRole('button',{name:'Search'}))
  expect(screen.getByText('Browse destination /events?search=Music+%26+food&date=weekend&village=Hag%C3%A5t%C3%B1a')).toBeInTheDocument()
 })
 it('uses current purchasable all-in prices and included fees on the cards', async()=>{
  apiClient.get.mockResolvedValue({data:{events:[{...event,ticket_types:[{price_cents:0,quantity_remaining:0},{price_cents:2500,all_in_price_cents:2725,service_fee_cents:225,quantity_remaining:20,on_sale:true}]}]}})
  mount(); expect(await screen.findByText('From $27.25')).toBeInTheDocument(); expect(screen.getByText('Includes $2.25 service fee')).toBeInTheDocument()
 })
 it('folds featured events into one row and sorts without mutating the API array', async()=>{
  const events=Object.freeze([{...event,id:38,slug:'later',title:'Later featured event',is_featured:true,starts_at:'2099-10-21T08:00:00Z'},event])
  apiClient.get.mockResolvedValue({data:{events}}); mount()
  const row=await screen.findByRole('list',{name:'Coming up'})
  expect(within(row).getAllByRole('link').map(a=>a.getAttribute('href'))).toEqual(['/events/later','/events/community-night'])
  expect(events.map(e=>e.id)).toEqual([38,37])
  expect(screen.getByRole('link',{name:'Food & Drink'})).toHaveAttribute('href','/events?category=dining')
 })
 it('falls back to the date tile when organizer artwork fails',async()=>{
  apiClient.get.mockResolvedValue({data:{events:[{...event,image_asset_host:'art.example.test',cover_image_url:'https://art.example.test/uploads/poster.jpg'}]}})
  mount(); fireEvent.error(await screen.findByRole('img',{name:event.title}))
  expect(screen.queryByRole('img')).not.toBeInTheDocument()
  expect(screen.getByLabelText('Tuesday, Oct 20, 2099')).toBeInTheDocument()
 })
})
