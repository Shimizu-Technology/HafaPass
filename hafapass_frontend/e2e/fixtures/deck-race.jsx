import '../../src/i18n'
import '../../src/index.css'
import React, { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { MemoryRouter } from 'react-router-dom'
import HeroFannedDeck from '../../src/components/HeroFannedDeck'
const events = [1, 2, 3].map(id => ({ id, slug: `event-${id}`, title: `Event ${id}`, starts_at: '2099-01-01T00:00:00Z', ticket_types: [] }))
export default function Harness() {
  const [inventory, setInventory] = useState(events)
  window.setDeckInventory = value => setInventory(value ? events : [])
  return <MemoryRouter><div style={{ width: 360 }}><HeroFannedDeck events={inventory} /></div></MemoryRouter>
}
createRoot(document.getElementById('root')).render(<Harness />)
