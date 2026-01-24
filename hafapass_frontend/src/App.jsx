import { Routes, Route } from 'react-router-dom'
import Layout from './components/Layout'
import ProtectedRoute from './components/ProtectedRoute'
import HomePage from './pages/HomePage'
import EventsPage from './pages/EventsPage'
import EventDetailPage from './pages/EventDetailPage'
import CheckoutPage from './pages/CheckoutPage'
import OrderConfirmationPage from './pages/OrderConfirmationPage'
import TicketPage from './pages/TicketPage'
import MyTicketsPage from './pages/MyTicketsPage'
import DashboardPage from './pages/dashboard/DashboardPage'
import CreateEventPage from './pages/dashboard/CreateEventPage'
import EditEventPage from './pages/dashboard/EditEventPage'
import SignInPage from './pages/SignInPage'
import SignUpPage from './pages/SignUpPage'

function App() {
  return (
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
        <Route path="/sign-in/*" element={<SignInPage />} />
        <Route path="/sign-up/*" element={<SignUpPage />} />
      </Route>
    </Routes>
  )
}

export default App
