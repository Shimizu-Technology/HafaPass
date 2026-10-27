import { lazy } from 'react'
import { Routes, Route, Navigate } from 'react-router-dom'
import HomePage from './pages/HomePage'
import Layout from './components/Layout'
import ProtectedRoute from './components/ProtectedRoute'
import AdminRoute from './components/AdminRoute'
import SupportRoute from './components/SupportRoute'
import { useAuthReturnIntentCleanup } from './hooks/useAuthReturnPath'

// Lazy-loaded — heavier pages loaded on demand
const EventsPage = lazy(() => import('./pages/EventsPage'))
const EventDetailPage = lazy(() => import('./pages/purchaseFlow').then(module => ({ default: module.EventDetailPage })))
const SignInPage = lazy(() => import('./pages/SignInPage'))
const SignUpPage = lazy(() => import('./pages/SignUpPage'))
const CheckoutPage = lazy(() => import('./pages/purchaseFlow').then(module => ({ default: module.CheckoutPage })))
const OrderConfirmationPage = lazy(() => import('./pages/purchaseFlow').then(module => ({ default: module.OrderConfirmationPage })))
const OrderRecoveryPage = lazy(() => import('./pages/purchaseFlow').then(module => ({ default: module.OrderRecoveryPage })))
const TicketPage = lazy(() => import('./pages/purchaseFlow').then(module => ({ default: module.TicketPage })))
const PolicyPage = lazy(() => import('./pages/PolicyPage'))
const UnsubscribePage = lazy(() => import('./pages/UnsubscribePage'))
const MyTicketsPage = lazy(() => import('./pages/MyTicketsPage'))
const DashboardPage = lazy(() => import('./pages/dashboard/DashboardPage'))
const CreateEventPage = lazy(() => import('./pages/dashboard/CreateEventPage'))
const EditEventPage = lazy(() => import('./pages/dashboard/EditEventPage'))
const EventOverviewPage = lazy(() => import('./pages/dashboard/EventOverviewPage'))
const EventAnalyticsPage = lazy(() => import('./pages/dashboard/EventAnalyticsPage'))
const ScannerPage = lazy(() => import('./pages/dashboard/ScannerPage'))
const SettingsPage = lazy(() => import('./pages/dashboard/SettingsPage'))
const ActivityPage = lazy(() => import('./pages/dashboard/ActivityPage'))
const FinancesPage = lazy(() => import('./pages/dashboard/FinancesPage'))
const InvitationAcceptPage = lazy(() => import('./pages/dashboard/InvitationAcceptPage'))
const PlatformInvitationAcceptPage = lazy(() => import('./pages/PlatformInvitationAcceptPage'))
const EventStaffPage = lazy(() => import('./pages/dashboard/EventStaffPage'))
const PromoCodesPage = lazy(() => import('./pages/dashboard/PromoCodesPage'))
const GuestListPage = lazy(() => import('./pages/dashboard/GuestListPage'))
const RefundsPage = lazy(() => import('./pages/dashboard/RefundsPage'))
const AttendeesPage = lazy(() => import('./pages/dashboard/AttendeesPage'))
const BoxOfficePage = lazy(() => import('./pages/dashboard/BoxOfficePage'))
const WaitlistPage = lazy(() => import('./pages/dashboard/WaitlistPage'))
const TicketTransferAcceptPage = lazy(() => import('./pages/purchaseFlow').then(module => ({ default: module.TicketTransferAcceptPage })))
const SalesToolsPage = lazy(() => import('./pages/dashboard/SalesToolsPage'))
const CollectionsPage = lazy(() => import('./pages/CollectionsPage'))
const CollectionPage = lazy(() => import('./pages/CollectionPage'))
const VenuePage = lazy(() => import('./pages/VenuePage'))
const OrganizerPage = lazy(() => import('./pages/OrganizerPage'))
const HostPage = lazy(() => import('./pages/HostPage'))
const DistributionRedirectPage = lazy(() => import('./pages/DistributionRedirectPage'))
const SavedPage = lazy(() => import('./pages/SavedPage'))
const SeatingManagementPage = lazy(() => import('./pages/dashboard/SeatingManagementPage'))
const NotFound = lazy(() => import('./components/NotFound'))

// Admin pages
const AdminDashboardPage = lazy(() => import('./pages/admin/AdminDashboardPage'))
const AdminEventsPage = lazy(() => import('./pages/admin/AdminEventsPage'))
const AdminUsersPage = lazy(() => import('./pages/admin/AdminUsersPage'))
const AdminOrdersPage = lazy(() => import('./pages/admin/AdminOrdersPage'))
const AdminOperationsPage = lazy(() => import('./pages/admin/AdminOperationsPage'))
const SupportPage = lazy(() => import('./pages/support/SupportPage'))
const MarketplaceAdminPage = lazy(() => import('./pages/admin/MarketplaceAdminPage'))
const ProviderReadinessPage = lazy(() => import('./pages/admin/ProviderReadinessPage'))
const AdminSettingsPage = lazy(() => import('./pages/admin/AdminSettingsPage'))
const AdminPrivacyPage = lazy(() => import('./pages/admin/AdminPrivacyPage'))
const PrivacyRequestsPage = lazy(() => import('./pages/PrivacyRequestsPage'))
const GuestPrivacyRequestsPage = lazy(() => import('./pages/PrivacyRequestsPage').then(module => ({ default: module.GuestPrivacyRequestsPage })))
const AdminPayoutsPage = lazy(() => import('./pages/admin/AdminPayoutsPage'))
const AdminDisputesPage = lazy(() => import('./pages/admin/AdminDisputesPage'))
const AdminRefundReconciliationPage = lazy(() => import('./pages/admin/AdminRefundReconciliationPage'))
const AdminAuditLogPage = lazy(() => import('./pages/admin/AdminAuditLogPage'))
const AdminTaxReportsPage = lazy(() => import('./pages/admin/AdminTaxReportsPage'))
const AdminTaxControlsPage = lazy(() => import('./pages/admin/AdminTaxControlsPage'))
const AdminOrganizationsPage = lazy(() => import('./pages/admin/AdminOrganizationsPage'))
const AdminOrganizationPage = lazy(() => import('./pages/admin/AdminOrganizationPage'))

function App() {
  useAuthReturnIntentCleanup()
  return (
      <Routes>
        <Route element={<Layout />}>
          <Route path="/" element={<HomePage />} />
          <Route path="/events" element={<EventsPage />} />
          <Route path="/events/:slug" element={<EventDetailPage />} />
          <Route path="/events/:slug/preview" element={<EventDetailPage />} />
          <Route path="/discover" element={<CollectionsPage />} />
          <Route path="/collections/:slug" element={<CollectionPage />} />
          <Route path="/venues/:slug" element={<VenuePage />} />
          <Route path="/organizers/:slug" element={<OrganizerPage />} />
          <Route path="/host" element={<HostPage />} />
          <Route path="/pricing" element={<Navigate to="/host#pricing" replace />} />
          <Route path="/go/:code" element={<DistributionRedirectPage />} />
          <Route path="/refer/:code" element={<DistributionRedirectPage />} />
          <Route path="/checkout/:slug" element={<CheckoutPage />} />
          <Route path="/orders/:id/confirmation" element={<OrderConfirmationPage />} />
          <Route path="/orders/recover" element={<OrderRecoveryPage />} />
          <Route path="/tickets/:credential" element={<TicketPage />} />
          <Route path="/policies/:policy" element={<PolicyPage />} />
          <Route path="/unsubscribe/:token" element={<UnsubscribePage />} />
          <Route path="/my-tickets" element={<ProtectedRoute><MyTicketsPage /></ProtectedRoute>} />
          <Route path="/privacy" element={<ProtectedRoute><PrivacyRequestsPage /></ProtectedRoute>} />
          <Route path="/account/settings" element={<ProtectedRoute><PrivacyRequestsPage /></ProtectedRoute>} />
          <Route path="/privacy/guest/:orderId" element={<GuestPrivacyRequestsPage />} />
          <Route path="/saved" element={<ProtectedRoute><SavedPage /></ProtectedRoute>} />
          <Route path="/ticket-transfers/accept" element={<ProtectedRoute><TicketTransferAcceptPage /></ProtectedRoute>} />
          <Route path="/dashboard" element={<ProtectedRoute><DashboardPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/new" element={<ProtectedRoute><CreateEventPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id" element={<ProtectedRoute><EventOverviewPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/edit" element={<ProtectedRoute><EditEventPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/analytics" element={<ProtectedRoute><EventAnalyticsPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/promo-codes" element={<ProtectedRoute><PromoCodesPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/guest-list" element={<ProtectedRoute><GuestListPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/refunds" element={<ProtectedRoute><RefundsPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/attendees" element={<ProtectedRoute><AttendeesPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/box-office" element={<ProtectedRoute><BoxOfficePage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/waitlist" element={<ProtectedRoute><WaitlistPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/sales-tools" element={<ProtectedRoute><SalesToolsPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/seating" element={<ProtectedRoute><SeatingManagementPage /></ProtectedRoute>} />
          <Route path="/dashboard/scanner" element={<ProtectedRoute><ScannerPage /></ProtectedRoute>} />
          <Route path="/dashboard/settings" element={<ProtectedRoute><SettingsPage /></ProtectedRoute>} />
          <Route path="/dashboard/settings/activity" element={<ProtectedRoute><ActivityPage /></ProtectedRoute>} />
          <Route path="/dashboard/finances" element={<ProtectedRoute><FinancesPage /></ProtectedRoute>} />
          <Route path="/dashboard/events/:id/team" element={<ProtectedRoute><EventStaffPage /></ProtectedRoute>} />
          <Route path="/organization-invitations/accept" element={<ProtectedRoute><InvitationAcceptPage /></ProtectedRoute>} />
          <Route path="/platform-invitations/accept" element={<ProtectedRoute><PlatformInvitationAcceptPage /></ProtectedRoute>} />
          {/* Admin routes */}
          <Route path="/admin" element={<AdminRoute><AdminDashboardPage /></AdminRoute>} />
          <Route path="/admin/events" element={<AdminRoute><AdminEventsPage /></AdminRoute>} />
          <Route path="/admin/users" element={<AdminRoute><AdminUsersPage /></AdminRoute>} />
          <Route path="/admin/organizations" element={<AdminRoute><AdminOrganizationsPage /></AdminRoute>} />
          <Route path="/admin/organizations/:id" element={<AdminRoute><AdminOrganizationPage /></AdminRoute>} />
          <Route path="/admin/orders" element={<AdminRoute><AdminOrdersPage /></AdminRoute>} />
          <Route path="/admin/marketplace" element={<AdminRoute><MarketplaceAdminPage /></AdminRoute>} />
          <Route path="/admin/provider-readiness" element={<AdminRoute><ProviderReadinessPage /></AdminRoute>} />
          <Route path="/admin/settings" element={<AdminRoute><AdminSettingsPage /></AdminRoute>} />
          <Route path="/admin/privacy" element={<AdminRoute><AdminPrivacyPage /></AdminRoute>} />
          <Route path="/admin/tax-reports" element={<AdminRoute><AdminTaxReportsPage /></AdminRoute>} />
          <Route path="/admin/tax-controls" element={<AdminRoute><AdminTaxControlsPage /></AdminRoute>} />
          <Route path="/admin/payouts" element={<AdminRoute><AdminPayoutsPage /></AdminRoute>} />
          <Route path="/admin/disputes" element={<AdminRoute><AdminDisputesPage /></AdminRoute>} />
          <Route path="/admin/refund_reconciliation" element={<AdminRoute><AdminRefundReconciliationPage /></AdminRoute>} />
          <Route path="/admin/audit-log" element={<AdminRoute><AdminAuditLogPage /></AdminRoute>} />
          <Route path="/admin/operations" element={<AdminRoute><AdminOperationsPage /></AdminRoute>} />
          <Route path="/support" element={<SupportRoute><SupportPage /></SupportRoute>} />
          <Route path="/sign-in/*" element={<SignInPage />} />
          <Route path="/sign-up/*" element={<SignUpPage />} />
          <Route path="*" element={<NotFound />} />
        </Route>
      </Routes>
  )
}

export default App
