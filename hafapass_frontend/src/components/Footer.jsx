import { Link } from 'react-router-dom'

export default function Footer() {
  return (
    <footer className="bg-brand-950 text-neutral-400 py-14">
      <div className="max-w-6xl mx-auto px-6 lg:px-8">
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-10 mb-10">
          {/* Brand */}
          <div className="lg:col-span-1">
            <div className="flex items-center gap-2 mb-4">
              <div className="w-8 h-8 rounded-lg bg-brand-500/20 flex items-center justify-center">
                <svg className="w-4.5 h-4.5 text-brand-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2Z" />
                </svg>
              </div>
              <span className="text-base font-bold text-neutral-200 tracking-tight">HafaPass</span>
            </div>
            <p className="text-sm text-neutral-500 leading-relaxed">
              Your pass to every event on Guam. Discover, book, and experience the island's best.
            </p>
          </div>

          {/* Platform */}
          <div>
            <h3 className="text-sm font-semibold text-neutral-300 uppercase tracking-wider mb-4">Platform</h3>
            <ul className="space-y-2.5">
              <li><Link to="/events" className="text-sm text-neutral-500 hover:text-neutral-300 transition-colors">Browse Events</Link></li>
              <li><Link to="/sign-up" className="text-sm text-neutral-500 hover:text-neutral-300 transition-colors">For Organizers</Link></li>
              <li><Link to="/sign-in" className="text-sm text-neutral-500 hover:text-neutral-300 transition-colors">Sign In</Link></li>
            </ul>
          </div>

          {/* Company */}
          <div>
            <h3 className="text-sm font-semibold text-neutral-300 uppercase tracking-wider mb-4">Company</h3>
            <ul className="space-y-2.5">
              <li><a href="https://shimizu-technology.com" target="_blank" rel="noopener noreferrer" className="text-sm text-neutral-500 hover:text-neutral-300 transition-colors">About</a></li>
              <li><a href="mailto:contact@hafapass.com" className="text-sm text-neutral-500 hover:text-neutral-300 transition-colors">Contact</a></li>
              <li><Link to="/" className="text-sm text-neutral-500 hover:text-neutral-300 transition-colors">Privacy Policy</Link></li>
            </ul>
          </div>

          {/* Social */}
          <div>
            <h3 className="text-sm font-semibold text-neutral-300 uppercase tracking-wider mb-4">Connect</h3>
            <div className="flex items-center gap-3">
              {/* Instagram */}
              <a href="https://instagram.com" target="_blank" rel="noopener noreferrer" className="w-9 h-9 rounded-lg bg-white/5 hover:bg-white/10 flex items-center justify-center transition-colors" aria-label="Instagram">
                <svg className="w-4 h-4 text-neutral-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <rect width="20" height="20" x="2" y="2" rx="5" ry="5"/><path d="M16 11.37A4 4 0 1 1 12.63 8 4 4 0 0 1 16 11.37z"/><line x1="17.5" x2="17.51" y1="6.5" y2="6.5"/>
                </svg>
              </a>
              {/* Facebook */}
              <a href="https://facebook.com" target="_blank" rel="noopener noreferrer" className="w-9 h-9 rounded-lg bg-white/5 hover:bg-white/10 flex items-center justify-center transition-colors" aria-label="Facebook">
                <svg className="w-4 h-4 text-neutral-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M18 2h-3a5 5 0 0 0-5 5v3H7v4h3v8h4v-8h3l1-4h-4V7a1 1 0 0 1 1-1h3z"/>
                </svg>
              </a>
              {/* X / Twitter */}
              <a href="https://x.com" target="_blank" rel="noopener noreferrer" className="w-9 h-9 rounded-lg bg-white/5 hover:bg-white/10 flex items-center justify-center transition-colors" aria-label="X">
                <svg className="w-4 h-4 text-neutral-400" viewBox="0 0 24 24" fill="currentColor">
                  <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z"/>
                </svg>
              </a>
            </div>
          </div>
        </div>

        {/* Divider + Copyright */}
        <div className="border-t border-white/5 pt-6 flex flex-col sm:flex-row items-center justify-between gap-3">
          <p className="text-xs text-neutral-600">
            &copy; {new Date().getFullYear()} Shimizu Technology. All rights reserved.
          </p>
          <p className="text-xs text-neutral-600">
            Made with aloha on Guam
          </p>
        </div>
      </div>
    </footer>
  )
}
