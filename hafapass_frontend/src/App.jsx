import { Routes, Route } from 'react-router-dom'
import Layout from './components/Layout'
import HomePage from './pages/HomePage'
import SignInPage from './pages/SignInPage'
import SignUpPage from './pages/SignUpPage'

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
