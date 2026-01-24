import { Outlet } from 'react-router-dom'
import Navbar from './Navbar'

export default function Layout() {
  return (
    <div className="min-h-screen flex flex-col bg-gray-50">
      <Navbar />
      <main className="flex-1">
        <Outlet />
      </main>
      <footer className="bg-blue-900 text-blue-200 py-6">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 text-center">
          <p className="text-sm">
            &copy; {new Date().getFullYear()} HafaPass. All rights reserved.
          </p>
          <p className="text-xs text-blue-300 mt-1">
            Powered by Shimizu Technology
          </p>
        </div>
      </footer>
    </div>
  )
}
