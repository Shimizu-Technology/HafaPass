import { Outlet, useLocation } from 'react-router-dom'
import Navbar from './Navbar'
import Footer from './Footer'

export default function Layout() {
  const location = useLocation()
  const isHomePage = location.pathname === '/'

  return (
    <div className="min-h-screen flex flex-col bg-neutral-50">
      <Navbar />
      <main className="flex-1">
        <Outlet />
      </main>
      {/* HomePage renders its own footer */}
      {!isHomePage && <Footer />}
    </div>
  )
}
