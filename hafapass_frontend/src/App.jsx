import { lazy, Suspense } from 'react'
import { Routes, Route } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import Layout from './components/Layout'
import ProtectedRoute from './components/ProtectedRoute'
import AdminRoute from './components/AdminRoute'

// Eagerly loaded — initial page load paths
import HomePage from './pages/HomePage'
import EventsPage from './pages/EventsPage'
import EventDetailPage from './pages/EventDetailPage'
import SignInPage from './pages/SignInPage'
import SignUpPage from './pages/SignUpPage'

// Lazy-loaded — heavier pages loaded on demand
const CheckoutPage = lazy(() => import('./pages/CheckoutPage'))
const OrderConfirmationPage = lazy(() => import('./pages/OrderConfirmationPage'))
const TicketPage = lazy(() => import('./pages/TicketPage'))
const MyTicketsPage = lazy(() => import('./pages/MyTicketsPage'))
const DashboardPage = lazy(() => import('./pages/dashboard/DashboardPage'))
const CreateEventPage = lazy(() => import('./pages/dashboard/CreateEventPage'))
const EditEventPage = lazy(() => import('./pages/dashboard/EditEventPage'))
const EventAnalyticsPage = lazy(() => import('./pages/dashboard/EventAnalyticsPage'))
const ScannerPage = lazy(() => import('./pages/dashboard/ScannerPage'))
const SettingsPage = lazy(() => import('./pages/dashboard/SettingsPage'))
const PromoCodesPage = lazy(() => import('./pages/dashboard/PromoCodesPage'))
const GuestListPage = lazy(() => import('./pages/dashboard/GuestListPage'))
const RefundsPage = lazy(() => import('./pages/dashboard/RefundsPage'))
const AttendeesPage = lazy(() => import('./pages/dashboard/AttendeesPage'))

// Admin pages
const AdminDashboardPage = lazy(() => import('./pages/admin/AdminDashboardPage'))
const AdminEventsPage = lazy(() => import('./pages/admin/AdminEventsPage'))
const AdminUsersPage = lazy(() => import('./pages/admin/AdminUsersPage'))
const AdminOrdersPage = lazy(() => import('./pages/admin/AdminOrdersPage'))

function PageLoader() {
  return (
    <div className="flex justify-center items-center py-20">
      <Loader2 className="w-8 h-8 text-brand-500 animate-spin" />
    </div>
  )
}

function App() {
  return (
    <Suspense fallback={<PageLoader />}>
      <Routes>
        <Route element={<Layout />}>
          <Route path="/" element={<HomePage />} />
          <Route path="/events" element={<EventsPage />} />
          <Route path="/events/:slug" element={<EventDetailPage />} />
          <Route path="/checkout/:slug" element={<CheckoutPage />} />
          <Route path="/orders/:id/confirmation" element={<OrderConfirmationPage />} />
          <Route path="/tickets/:qrCode" element={<TicketPage />} />
          <Route path="/my-tickets" element={<ProtectedRoute><MyTicketsPage /></ProtectedRoute>} />
          <Route path="/dashboard" element={<ProtectedRoute><DashboardPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/new" element={<ProtectedRoute><CreateEventPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/edit" element={<ProtectedRoute><EditEventPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/analytics" element={<ProtectedRoute><EventAnalyticsPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/promo-codes" element={<ProtectedRoute><PromoCodesPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/guest-list" element={<ProtectedRoute><GuestListPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/refunds" element={<ProtectedRoute><RefundsPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/attendees" element={<ProtectedRoute><AttendeesPage /></ProtectedRoute>} />
          <Route path="/dashboard/scanner" element={<ProtectedRoute><ScannerPage /></ProtectedRoute>} />
          <Route path="/dashboard/settings" element={<ProtectedRoute><SettingsPage /></ProtectedRoute>} />
          {/* Admin routes */}
          <Route path="/admin" element={<AdminRoute><AdminDashboardPage /></AdminRoute>} />
          <Route path="/admin/events" element={<AdminRoute><AdminEventsPage /></AdminRoute>} />
          <Route path="/admin/users" element={<AdminRoute><AdminUsersPage /></AdminRoute>} />
          <Route path="/admin/orders" element={<AdminRoute><AdminOrdersPage /></AdminRoute>} />
          <Route path="/sign-in/*" element={<SignInPage />} />
          <Route path="/sign-up/*" element={<SignUpPage />} />
        </Route>
      </Routes>
    </Suspense>
  )
}

export default App
