import { Routes, Route } from 'react-router-dom'

function HomePage() {
  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-blue-900 to-teal-600">
      <div className="text-center text-white">
        <h1 className="text-5xl font-bold mb-4">HafaPass</h1>
        <p className="text-xl text-blue-100">Your Island. Your Events. Your Pass.</p>
      </div>
    </div>
  )
}

function App() {
  return (
    <Routes>
      <Route path="/" element={<HomePage />} />
    </Routes>
  )
}

export default App
