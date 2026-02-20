import { Link } from 'react-router-dom'
import { motion } from 'framer-motion'
import { ArrowRight, Ticket, Shield, Zap, QrCode, Users, CreditCard } from 'lucide-react'
import Footer from '../components/Footer'

const features = [
  {
    icon: Ticket,
    title: 'Digital Tickets',
    description: 'Beautiful mobile tickets with QR codes. No more lost paper tickets or printing hassles.',
  },
  {
    icon: Shield,
    title: 'Secure Payments',
    description: 'Stripe-powered checkout with Apple Pay, Google Pay, and all major cards.',
  },
  {
    icon: Zap,
    title: 'Instant Delivery',
    description: 'Tickets delivered to email instantly. Access them anytime from your phone.',
  },
  {
    icon: QrCode,
    title: 'QR Check-In',
    description: 'Fast entry with QR code scanning. Real-time check-in tracking for organizers.',
  },
  {
    icon: Users,
    title: 'Guest Lists',
    description: 'Manage comp tickets and guest lists effortlessly. Perfect for VIPs and promotions.',
  },
  {
    icon: CreditCard,
    title: 'Promo Codes',
    description: 'Create percentage or fixed-amount discounts. Drive sales with targeted promotions.',
  },
]

export default function HomePage() {
  return (
    <div className="min-h-screen">
      {/* Hero */}
      <section className="relative overflow-hidden bg-gradient-to-b from-brand-950 via-brand-900 to-brand-800 text-white">
        {/* Background grid */}
        <div className="absolute inset-0 bg-[linear-gradient(to_right,rgba(255,255,255,0.03)_1px,transparent_1px),linear-gradient(to_bottom,rgba(255,255,255,0.03)_1px,transparent_1px)] bg-[size:32px_32px]" />
        <div className="absolute top-0 left-1/2 -translate-x-1/2 w-[600px] h-[400px] bg-accent-500/10 rounded-full blur-[120px]" />

        <div className="relative max-w-6xl mx-auto px-6 lg:px-8 pt-20 pb-24 lg:pt-28 lg:pb-32">
          <div className="max-w-3xl">
            <motion.div
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.5 }}
            >
              <div className="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-white/5 border border-white/10 text-sm text-neutral-300 mb-8 backdrop-blur-sm">
                <span className="w-2 h-2 rounded-full bg-emerald-400 animate-pulse" />
                Now live on Guam
              </div>
            </motion.div>

            <motion.h1
              className="text-4xl sm:text-5xl lg:text-6xl font-bold tracking-tight leading-[1.1] mb-6"
              initial={{ opacity: 0, y: 30 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.7, delay: 0.1, ease: [0.22, 1, 0.36, 1] }}
            >
              Your pass to{' '}
              <span className="bg-gradient-to-r from-accent-400 to-accent-500 bg-clip-text text-transparent">
                every event
              </span>
              {' '}on the island
            </motion.h1>

            <motion.p
              className="text-lg sm:text-xl text-neutral-300 max-w-xl mb-10 leading-relaxed"
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
                className="group inline-flex items-center justify-center gap-2 px-8 py-4 bg-accent-500 text-white rounded-xl font-semibold text-lg transition-all duration-200 hover:bg-accent-600 hover:shadow-lg hover:shadow-accent-500/30 hover:-translate-y-0.5"
              >
                Browse Events
                <ArrowRight className="w-5 h-5 transition-transform group-hover:translate-x-1" />
              </Link>
              <Link
                to="/sign-up"
                className="inline-flex items-center justify-center px-8 py-4 text-white/90 hover:text-white font-semibold text-lg transition-colors"
              >
                Create an Event
              </Link>
            </motion.div>
          </div>
        </div>
      </section>

      {/* Features */}
      <section className="py-20 lg:py-28">
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
              return (
                <motion.div
                  key={feature.title}
                  initial={{ opacity: 0, y: 20 }}
                  whileInView={{ opacity: 1, y: 0 }}
                  viewport={{ once: true, margin: '-10%' }}
                  transition={{ duration: 0.5, delay: i * 0.08 }}
                  className="group p-7 rounded-2xl bg-white border border-neutral-200/60 hover:border-brand-500/30 hover:shadow-lg hover:shadow-brand-500/5 transition-all duration-300"
                >
                  <div className="w-11 h-11 rounded-xl bg-brand-50 flex items-center justify-center mb-5 group-hover:bg-brand-500 transition-colors duration-300">
                    <Icon className="w-5 h-5 text-brand-500 group-hover:text-white transition-colors duration-300" />
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
      <section className="py-20 lg:py-28 bg-neutral-100/50">
        <div className="max-w-4xl mx-auto px-6 lg:px-8 text-center">
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
              <Link to="/events" className="text-neutral-500 hover:text-neutral-900 font-medium text-lg transition-colors">
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
