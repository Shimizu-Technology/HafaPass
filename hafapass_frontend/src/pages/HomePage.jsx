import { Link } from 'react-router-dom'
import { motion } from 'framer-motion'
import { ArrowRight, Ticket, Shield, Zap, QrCode, Users, CreditCard } from 'lucide-react'
import Footer from '../components/Footer'

const features = [
  {
    icon: Ticket,
    title: 'Digital Tickets',
    description: 'Beautiful mobile tickets with QR codes. No more lost paper tickets or printing hassles.',
    color: 'brand',
  },
  {
    icon: Shield,
    title: 'Secure Payments',
    description: 'Stripe-powered checkout with Apple Pay, Google Pay, and all major cards.',
    color: 'indigo',
  },
  {
    icon: Zap,
    title: 'Instant Delivery',
    description: 'Tickets delivered to email instantly. Access them anytime from your phone.',
    color: 'amber',
  },
  {
    icon: QrCode,
    title: 'QR Check-In',
    description: 'Fast entry with QR code scanning. Real-time check-in tracking for organizers.',
    color: 'emerald',
  },
  {
    icon: Users,
    title: 'Guest Lists',
    description: 'Manage comp tickets and guest lists effortlessly. Perfect for VIPs and promotions.',
    color: 'violet',
  },
  {
    icon: CreditCard,
    title: 'Promo Codes',
    description: 'Create percentage or fixed-amount discounts. Drive sales with targeted promotions.',
    color: 'rose',
  },
]

const iconColorMap = {
  brand:   { bg: 'bg-brand-50', icon: 'text-brand-500', hoverBg: 'group-hover:bg-brand-500' },
  indigo:  { bg: 'bg-indigo-50', icon: 'text-indigo-500', hoverBg: 'group-hover:bg-indigo-500' },
  amber:   { bg: 'bg-amber-50', icon: 'text-amber-500', hoverBg: 'group-hover:bg-amber-500' },
  emerald: { bg: 'bg-emerald-50', icon: 'text-emerald-500', hoverBg: 'group-hover:bg-emerald-500' },
  violet:  { bg: 'bg-violet-50', icon: 'text-violet-500', hoverBg: 'group-hover:bg-violet-500' },
  rose:    { bg: 'bg-rose-50', icon: 'text-rose-500', hoverBg: 'group-hover:bg-rose-500' },
}

export default function HomePage() {
  return (
    <div className="min-h-screen">
      {/* Hero */}
      <section className="relative overflow-hidden">
        {/* Gradient mesh background — light & sophisticated */}
        <div className="absolute inset-0 bg-gradient-to-br from-neutral-50 via-white to-brand-50/30" />
        <div className="absolute top-0 right-0 w-[800px] h-[600px] bg-gradient-to-bl from-brand-100/40 via-transparent to-transparent rounded-full blur-3xl" />
        <div className="absolute bottom-0 left-0 w-[600px] h-[400px] bg-gradient-to-tr from-accent-100/20 via-transparent to-transparent rounded-full blur-3xl" />
        <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 w-[500px] h-[500px] bg-brand-200/10 rounded-full blur-[100px]" />

        {/* Subtle dot pattern */}
        <div className="absolute inset-0 bg-[radial-gradient(circle_at_1px_1px,rgba(13,158,150,0.05)_1px,transparent_0)] bg-[size:24px_24px]" />

        <div className="relative max-w-6xl mx-auto px-6 lg:px-8 pt-20 pb-24 lg:pt-28 lg:pb-36">
          <div className="max-w-3xl">
            <motion.div
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.5 }}
            >
              <div className="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-white border border-neutral-200/80 text-sm text-neutral-600 mb-8 shadow-soft">
                <span className="w-2 h-2 rounded-full bg-emerald-400 animate-pulse-soft" />
                Now live on Guam
              </div>
            </motion.div>

            <motion.h1
              className="text-4xl sm:text-5xl lg:text-6xl font-bold tracking-tight leading-[1.1] mb-6 text-neutral-900"
              initial={{ opacity: 0, y: 30 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.7, delay: 0.1, ease: [0.22, 1, 0.36, 1] }}
            >
              Your pass to{' '}
              <span className="bg-gradient-to-r from-brand-500 to-brand-600 bg-clip-text text-transparent">
                every event
              </span>
              {' '}on the island
            </motion.h1>

            <motion.p
              className="text-lg sm:text-xl text-neutral-500 max-w-xl mb-10 leading-relaxed"
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.6, delay: 0.3, ease: [0.22, 1, 0.36, 1] }}
            >
              Discover events, buy tickets, and check in with your phone.
              The modern ticketing platform built for Guam.
            </motion.p>

            <motion.div
              className="flex flex-col sm:flex-row gap-4"
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.6, delay: 0.5, ease: [0.22, 1, 0.36, 1] }}
            >
              <Link
                to="/events"
                className="group btn-primary text-lg !px-8 !py-4"
              >
                Browse Events
                <ArrowRight className="w-5 h-5 ml-2 transition-transform group-hover:translate-x-1" />
              </Link>
              <Link
                to="/sign-up"
                className="btn-secondary text-lg !px-8 !py-4"
              >
                Create an Event
              </Link>
            </motion.div>
          </div>

          {/* Floating card mockup for visual interest */}
          <motion.div
            className="hidden lg:block absolute right-8 top-1/2 -translate-y-1/2"
            initial={{ opacity: 0, x: 40 }}
            animate={{ opacity: 1, x: 0 }}
            transition={{ duration: 0.8, delay: 0.6, ease: [0.22, 1, 0.36, 1] }}
          >
            <div className="animate-float">
              <div className="w-72 bg-white rounded-2xl shadow-float border border-neutral-200/60 overflow-hidden">
                <div className="h-36 bg-gradient-to-br from-brand-400 via-brand-500 to-brand-600 relative">
                  <div className="absolute inset-0 bg-[radial-gradient(circle_at_70%_30%,rgba(255,255,255,0.15),transparent)]" />
                  <div className="absolute bottom-3 left-4 right-4">
                    <div className="text-white/80 text-xs font-medium">Featured Event</div>
                    <div className="text-white text-sm font-bold">Island Music Festival</div>
                  </div>
                </div>
                <div className="p-4 space-y-2.5">
                  <div className="flex items-center gap-2 text-xs text-neutral-500">
                    <span className="w-3 h-3 rounded-full bg-brand-100 flex items-center justify-center">
                      <span className="w-1.5 h-1.5 rounded-full bg-brand-500" />
                    </span>
                    Sat, Mar 15 · 6:00 PM
                  </div>
                  <div className="flex items-center gap-2 text-xs text-neutral-500">
                    <span className="w-3 h-3 rounded-full bg-accent-100 flex items-center justify-center">
                      <span className="w-1.5 h-1.5 rounded-full bg-accent-500" />
                    </span>
                    Tumon Bay, Guam
                  </div>
                  <div className="flex items-center justify-between pt-1">
                    <span className="text-xs font-bold text-accent-500">From $25</span>
                    <span className="text-[10px] font-medium text-emerald-600 bg-emerald-50 px-2 py-0.5 rounded-full">Tickets Available</span>
                  </div>
                </div>
              </div>
            </div>
          </motion.div>
        </div>
      </section>

      {/* Features */}
      <section className="py-20 lg:py-28 relative">
        <div className="max-w-6xl mx-auto px-6 lg:px-8">
          <div className="max-w-2xl mb-14">
            <h2 className="text-3xl lg:text-4xl font-bold tracking-tight text-neutral-900 mb-4">
              Everything you need,{' '}
              <span className="text-neutral-400">nothing you don't</span>
            </h2>
            <p className="text-lg text-neutral-500">
              From discovery to check-in, HafaPass handles the entire event experience.
            </p>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-5">
            {features.map((feature, i) => {
              const Icon = feature.icon
              const colors = iconColorMap[feature.color]
              return (
                <motion.div
                  key={feature.title}
                  initial={{ opacity: 0, y: 20 }}
                  whileInView={{ opacity: 1, y: 0 }}
                  viewport={{ once: true, margin: '-10%' }}
                  transition={{ duration: 0.5, delay: i * 0.08 }}
                  className="group p-7 rounded-2xl bg-white border border-neutral-200/60 hover:border-neutral-300/80 hover:shadow-card-hover transition-all duration-300 hover:-translate-y-0.5"
                >
                  <div className={`w-11 h-11 rounded-xl ${colors.bg} flex items-center justify-center mb-5 ${colors.hoverBg} transition-colors duration-300`}>
                    <Icon className={`w-5 h-5 ${colors.icon} group-hover:text-white transition-colors duration-300`} />
                  </div>
                  <h3 className="text-lg font-semibold text-neutral-900 mb-2">{feature.title}</h3>
                  <p className="text-neutral-500 text-sm leading-relaxed">{feature.description}</p>
                </motion.div>
              )
            })}
          </div>
        </div>
      </section>

      {/* CTA */}
      <section className="py-20 lg:py-28 relative">
        {/* Subtle background */}
        <div className="absolute inset-0 bg-gradient-to-b from-transparent via-neutral-100/50 to-transparent" />

        <div className="relative max-w-4xl mx-auto px-6 lg:px-8 text-center">
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true }}
            transition={{ duration: 0.6 }}
          >
            <h2 className="text-3xl lg:text-5xl font-bold tracking-tight text-neutral-900 mb-6">
              Ready to host your{' '}
              <span className="bg-gradient-to-r from-accent-500 to-accent-600 bg-clip-text text-transparent">
                next event
              </span>
              ?
            </h2>
            <p className="text-lg text-neutral-500 max-w-xl mx-auto mb-10">
              Create your organizer profile and start selling tickets in minutes. No setup fees.
            </p>
            <div className="flex flex-col sm:flex-row items-center justify-center gap-4">
              <Link to="/sign-up" className="btn-primary text-lg !px-8 !py-4">
                Get Started Free
              </Link>
              <Link to="/events" className="btn-ghost text-lg">
                View Events
              </Link>
            </div>
          </motion.div>
        </div>
      </section>

      <Footer />
    </div>
  )
}
