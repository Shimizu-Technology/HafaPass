import { lazy, Suspense } from 'react'
import { Routes, Route } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import Layout from './components/Layout'
import ProtectedRoute from './components/ProtectedRoute'
import AdminRoute from './components/AdminRoute'
import SupportRoute from './components/SupportRoute'

// Lazy-loaded — heavier pages loaded on demand
const HomePage = lazy(() => import('./pages/HomePage'))
const EventsPage = lazy(() => import('./pages/EventsPage'))
const EventDetailPage = lazy(() => import('./pages/EventDetailPage'))
const SignInPage = lazy(() => import('./pages/SignInPage'))
const SignUpPage = lazy(() => import('./pages/SignUpPage'))
const CheckoutPage = lazy(() => import('./pages/CheckoutPage'))
const OrderConfirmationPage = lazy(() => import('./pages/OrderConfirmationPage'))
const OrderRecoveryPage = lazy(() => import('./pages/OrderRecoveryPage'))
const TicketPage = lazy(() => import('./pages/TicketPage'))
const PolicyPage = lazy(() => import('./pages/PolicyPage'))
const MyTicketsPage = lazy(() => import('./pages/MyTicketsPage'))
const DashboardPage = lazy(() => import('./pages/dashboard/DashboardPage'))
const CreateEventPage = lazy(() => import('./pages/dashboard/CreateEventPage'))
const EditEventPage = lazy(() => import('./pages/dashboard/EditEventPage'))
const EventAnalyticsPage = lazy(() => import('./pages/dashboard/EventAnalyticsPage'))
const ScannerPage = lazy(() => import('./pages/dashboard/ScannerPage'))
const SettingsPage = lazy(() => import('./pages/dashboard/SettingsPage'))
const InvitationAcceptPage = lazy(() => import('./pages/dashboard/InvitationAcceptPage'))
const EventStaffPage = lazy(() => import('./pages/dashboard/EventStaffPage'))
const PromoCodesPage = lazy(() => import('./pages/dashboard/PromoCodesPage'))
const GuestListPage = lazy(() => import('./pages/dashboard/GuestListPage'))
const RefundsPage = lazy(() => import('./pages/dashboard/RefundsPage'))
const AttendeesPage = lazy(() => import('./pages/dashboard/AttendeesPage'))
const BoxOfficePage = lazy(() => import('./pages/dashboard/BoxOfficePage'))
const WaitlistPage = lazy(() => import('./pages/dashboard/WaitlistPage'))
const TicketTransferAcceptPage = lazy(() => import('./pages/TicketTransferAcceptPage'))
const SalesToolsPage = lazy(() => import('./pages/dashboard/SalesToolsPage'))
const CollectionsPage = lazy(() => import('./pages/CollectionsPage'))
const CollectionPage = lazy(() => import('./pages/CollectionPage'))
const VenuePage = lazy(() => import('./pages/VenuePage'))
const OrganizerPage = lazy(() => import('./pages/OrganizerPage'))
const DistributionRedirectPage = lazy(() => import('./pages/DistributionRedirectPage'))
const SavedPage = lazy(() => import('./pages/SavedPage'))

// Admin pages
const AdminDashboardPage = lazy(() => import('./pages/admin/AdminDashboardPage'))
const AdminEventsPage = lazy(() => import('./pages/admin/AdminEventsPage'))
const AdminUsersPage = lazy(() => import('./pages/admin/AdminUsersPage'))
const AdminOrdersPage = lazy(() => import('./pages/admin/AdminOrdersPage'))
const SupportPage = lazy(() => import('./pages/support/SupportPage'))
const MarketplaceAdminPage = lazy(() => import('./pages/admin/MarketplaceAdminPage'))

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
          <Route path="/discover" element={<CollectionsPage />} />
          <Route path="/collections/:slug" element={<CollectionPage />} />
          <Route path="/venues/:slug" element={<VenuePage />} />
          <Route path="/organizers/:slug" element={<OrganizerPage />} />
          <Route path="/go/:code" element={<DistributionRedirectPage />} />
          <Route path="/refer/:code" element={<DistributionRedirectPage />} />
          <Route path="/checkout/:slug" element={<CheckoutPage />} />
          <Route path="/orders/:id/confirmation" element={<OrderConfirmationPage />} />
          <Route path="/orders/recover" element={<OrderRecoveryPage />} />
          <Route path="/tickets/:credential" element={<TicketPage />} />
          <Route path="/policies/:policy" element={<PolicyPage />} />
          <Route path="/my-tickets" element={<ProtectedRoute><MyTicketsPage /></ProtectedRoute>} />
          <Route path="/saved" element={<ProtectedRoute><SavedPage /></ProtectedRoute>} />
          <Route path="/ticket-transfers/accept" element={<ProtectedRoute><TicketTransferAcceptPage /></ProtectedRoute>} />
          <Route path="/dashboard" element={<ProtectedRoute><DashboardPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/new" element={<ProtectedRoute><CreateEventPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/edit" element={<ProtectedRoute><EditEventPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/analytics" element={<ProtectedRoute><EventAnalyticsPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/promo-codes" element={<ProtectedRoute><PromoCodesPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/guest-list" element={<ProtectedRoute><GuestListPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/refunds" element={<ProtectedRoute><RefundsPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/attendees" element={<ProtectedRoute><AttendeesPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/box-office" element={<ProtectedRoute><BoxOfficePage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/waitlist" element={<ProtectedRoute><WaitlistPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/sales-tools" element={<ProtectedRoute><SalesToolsPage /></ProtectedRoute>} />
          <Route path="/dashboard/scanner" element={<ProtectedRoute><ScannerPage /></ProtectedRoute>} />
          <Route path="/dashboard/settings" element={<ProtectedRoute><SettingsPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/team" element={<ProtectedRoute><EventStaffPage /></ProtectedRoute>} />
          <Route path="/organization-invitations/accept" element={<ProtectedRoute><InvitationAcceptPage /></ProtectedRoute>} />
          {/* Admin routes */}
          <Route path="/admin" element={<AdminRoute><AdminDashboardPage /></AdminRoute>} />
          <Route path="/admin/events" element={<AdminRoute><AdminEventsPage /></AdminRoute>} />
          <Route path="/admin/users" element={<AdminRoute><AdminUsersPage /></AdminRoute>} />
          <Route path="/admin/orders" element={<AdminRoute><AdminOrdersPage /></AdminRoute>} />
          <Route path="/admin/marketplace" element={<AdminRoute><MarketplaceAdminPage /></AdminRoute>} />
          <Route path="/support" element={<SupportRoute><SupportPage /></SupportRoute>} />
          <Route path="/sign-in/*" element={<SignInPage />} />
          <Route path="/sign-up/*" element={<SignUpPage />} />
        </Route>
      </Routes>
    </Suspense>
  )
}

export default App
