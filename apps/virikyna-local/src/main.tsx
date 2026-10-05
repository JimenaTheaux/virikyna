import React from 'react'
import ReactDOM from 'react-dom/client'
import { HashRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { disableNumberInputScroll } from '@virikyna/shared'
import App from './App'
import { AuthProvider } from './auth/AuthContext'
import { Toaster } from './components/Toaster'
import { checkForUpdates } from './lib/updater'
import './index.css'

disableNumberInputScroll()
void checkForUpdates()

// Mismos defaults que Virikyna Gestión — hoy solo lo usa la card compartida de Stock bajo.
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      refetchOnWindowFocus: false,
    },
  },
})

ReactDOM.createRoot(document.getElementById('root') as HTMLElement).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <HashRouter>
        <AuthProvider>
          <App />
        </AuthProvider>
        <Toaster />
      </HashRouter>
    </QueryClientProvider>
  </React.StrictMode>,
)
