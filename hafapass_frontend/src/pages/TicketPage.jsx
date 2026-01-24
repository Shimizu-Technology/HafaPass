import { useState, useEffect } from 'react';
import { useParams, Link } from 'react-router-dom';
import api from '../api/client';
import QRCode from '../components/QRCode';

export default function TicketPage() {
  const { qrCode } = useParams();
  const [ticket, setTicket] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    async function fetchTicket() {
      try {
        setLoading(true);
        setError(null);
        const response = await api.get(`/tickets/${qrCode}`);
        setTicket(response.data);
      } catch (err) {
        if (err.response?.status === 404) {
          setError('Ticket not found.');
        } else {
          setError('Failed to load ticket. Please try again.');
        }
      } finally {
        setLoading(false);
      }
    }
    fetchTicket();
  }, [qrCode]);

  if (loading) {
    return (
      <div className="flex justify-center items-center min-h-[60vh]">
        <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-600"></div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="max-w-md mx-auto px-4 py-12 text-center">
        <div className="bg-red-50 border border-red-200 rounded-lg p-6">
          <svg className="w-12 h-12 text-red-400 mx-auto mb-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L4.082 16.5c-.77.833.192 2.5 1.732 2.5z" />
          </svg>
          <p className="text-red-700 font-medium">{error}</p>
          <Link to="/events" className="mt-4 inline-block text-blue-600 hover:underline text-sm">
            Browse Events
          </Link>
        </div>
      </div>
    );
  }

  const { event, ticket_type } = ticket;

  const formatDate = (dateStr) => {
    const date = new Date(dateStr);
    return date.toLocaleDateString('en-US', {
      weekday: 'long',
      year: 'numeric',
      month: 'long',
      day: 'numeric',
    });
  };

  const formatTime = (dateStr) => {
    const date = new Date(dateStr);
    return date.toLocaleTimeString('en-US', {
      hour: 'numeric',
      minute: '2-digit',
    });
  };

  const statusConfig = {
    issued: { label: 'Valid', bgColor: 'bg-green-100', textColor: 'text-green-800', borderColor: 'border-green-200' },
    checked_in: { label: 'Used', bgColor: 'bg-gray-100', textColor: 'text-gray-600', borderColor: 'border-gray-200' },
    cancelled: { label: 'Cancelled', bgColor: 'bg-red-100', textColor: 'text-red-800', borderColor: 'border-red-200' },
    transferred: { label: 'Transferred', bgColor: 'bg-yellow-100', textColor: 'text-yellow-800', borderColor: 'border-yellow-200' },
  };

  const status = statusConfig[ticket.status] || statusConfig.issued;

  return (
    <div className="min-h-[60vh] flex items-center justify-center px-3 sm:px-4 py-8">
      <div className="w-full max-w-[340px] sm:max-w-sm bg-white rounded-2xl shadow-lg overflow-hidden">
        {/* Status Badge */}
        <div className={`px-4 py-2 ${status.bgColor} ${status.borderColor} border-b text-center`}>
          <span className={`text-sm font-semibold ${status.textColor}`}>
            {status.label}
          </span>
          {ticket.status === 'checked_in' && ticket.checked_in_at && (
            <span className={`block text-xs ${status.textColor} opacity-75`}>
              Checked in at {formatTime(ticket.checked_in_at)}
            </span>
          )}
        </div>

        {/* QR Code Section */}
        <div className="px-4 sm:px-6 pt-6 pb-4 flex flex-col items-center">
          <div className="bg-white p-2 sm:p-3 rounded-lg border border-gray-100">
            <QRCode value={ticket.qr_code} size={220} />
          </div>
          <p className="mt-2 text-[10px] sm:text-xs text-gray-400 font-mono break-all text-center">{ticket.qr_code}</p>
        </div>

        {/* Divider */}
        <div className="relative px-6">
          <div className="absolute left-0 top-1/2 -translate-y-1/2 w-4 h-8 bg-gray-50 rounded-r-full"></div>
          <div className="absolute right-0 top-1/2 -translate-y-1/2 w-4 h-8 bg-gray-50 rounded-l-full"></div>
          <div className="border-t border-dashed border-gray-200"></div>
        </div>

        {/* Event Details */}
        <div className="px-4 sm:px-6 py-4 space-y-3">
          <div>
            <h2 className="text-lg font-bold text-gray-900">{event.title}</h2>
            <p className="text-sm text-blue-600 font-medium">{ticket_type.name}</p>
          </div>

          <div className="space-y-2">
            <div className="flex items-start gap-2">
              <svg className="w-4 h-4 text-gray-400 mt-0.5 flex-shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z" />
              </svg>
              <div>
                <p className="text-sm text-gray-700">{formatDate(event.starts_at)}</p>
                <p className="text-xs text-gray-500">
                  {formatTime(event.starts_at)}
                  {event.ends_at && ` – ${formatTime(event.ends_at)}`}
                </p>
              </div>
            </div>

            <div className="flex items-start gap-2">
              <svg className="w-4 h-4 text-gray-400 mt-0.5 flex-shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z" />
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 11a3 3 0 11-6 0 3 3 0 016 0z" />
              </svg>
              <div>
                <p className="text-sm text-gray-700">{event.venue_name}</p>
                {event.venue_address && (
                  <p className="text-xs text-gray-500">{event.venue_address}</p>
                )}
              </div>
            </div>

            {event.doors_open_at && (
              <div className="flex items-center gap-2">
                <svg className="w-4 h-4 text-gray-400 flex-shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                <p className="text-xs text-gray-500">Doors open at {formatTime(event.doors_open_at)}</p>
              </div>
            )}
          </div>

          {/* Attendee Info */}
          {ticket.attendee_name && (
            <div className="pt-2 border-t border-gray-100">
              <p className="text-xs text-gray-500">Attendee</p>
              <p className="text-sm font-medium text-gray-800">{ticket.attendee_name}</p>
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="px-4 sm:px-6 py-3 bg-gray-50 text-center">
          <p className="text-xs text-gray-400">Present this QR code at the door</p>
        </div>
      </div>
    </div>
  );
}
