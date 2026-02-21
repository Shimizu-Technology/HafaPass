import './i18n'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { HelmetProvider } from 'react-helmet-async'
import ClerkProviderWrapper from './components/ClerkProviderWrapper'
import './index.css'
import App from './App.jsx'

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <HelmetProvider>
      <BrowserRouter>
        <ClerkProviderWrapper>
          <App />
        </ClerkProviderWrapper>
      </BrowserRouter>
    </HelmetProvider>
  </StrictMode>,
)
