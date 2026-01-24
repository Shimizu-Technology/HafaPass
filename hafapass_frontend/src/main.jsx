import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import ClerkProviderWrapper from './components/ClerkProviderWrapper'
import './index.css'
import App from './App.jsx'

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <BrowserRouter>
      <ClerkProviderWrapper>
        <App />
      </ClerkProviderWrapper>
    </BrowserRouter>
  </StrictMode>,
)
