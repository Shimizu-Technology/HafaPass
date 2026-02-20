import { Link, useLocation } from 'react-router-dom'
import { BarChart3, Calendar, Users, ShoppingCart, Shield } from 'lucide-react'

const navItems = [
  { to: '/admin', label: 'Dashboard', icon: BarChart3, exact: true },
  { to: '/admin/events', label: 'Events', icon: Calendar },
  { to: '/admin/users', label: 'Users', icon: Users },
  { to: '/admin/orders', label: 'Orders', icon: ShoppingCart },
]

export default function AdminLayout({ children }) {
  const location = useLocation()

  const isActive = (path, exact) =>
    exact ? location.pathname === path : location.pathname.startsWith(path)

  return (
    <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div className="flex items-center gap-3 mb-8">
        <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-brand-500 to-brand-700 flex items-center justify-center shadow-md">
          <Shield className="w-5 h-5 text-white" />
        </div>
        <div>
          <h1 className="text-2xl font-bold text-neutral-900">Admin Panel</h1>
          <p className="text-sm text-neutral-500">Platform administration</p>
        </div>
      </div>

      <div className="flex gap-2 mb-8 overflow-x-auto pb-2">
        {navItems.map(item => {
          const Icon = item.icon
          const active = isActive(item.to, item.exact)
          return (
            <Link
              key={item.to}
              to={item.to}
              className={`flex items-center gap-2 px-4 py-2.5 rounded-xl text-sm font-medium whitespace-nowrap transition-all ${
                active
                  ? 'bg-brand-500 text-white shadow-md shadow-brand-500/20'
                  : 'bg-white/60 text-neutral-600 hover:bg-white hover:text-neutral-900 border border-neutral-200/50'
              }`}
            >
              <Icon className="w-4 h-4" />
              {item.label}
            </Link>
          )
        })}
      </div>

      {children}
    </div>
  )
}
