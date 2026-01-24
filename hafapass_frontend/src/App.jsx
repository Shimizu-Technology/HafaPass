import { Routes, Route } from 'react-router-dom'
import Layout from './components/Layout'
import SignInPage from './pages/SignInPage'
import SignUpPage from './pages/SignUpPage'

function HomePage() {
  return (
    <div className="flex items-center justify-center bg-gradient-to-br from-blue-900 to-teal-600" style={{ minHeight: 'calc(100vh - 64px - 88px)' }}>
      <div className="text-center text-white px-4">
        <h1 className="text-5xl font-bold mb-4">HafaPass</h1>
        <p className="text-xl text-blue-100">Your Island. Your Events. Your Pass.</p>
      </div>
    </div>
  )
}

function App() {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route path="/" element={<HomePage />} />
        <Route path="/sign-in/*" element={<SignInPage />} />
        <Route path="/sign-up/*" element={<SignUpPage />} />
      </Route>
    </Routes>
  )
}

export default App
