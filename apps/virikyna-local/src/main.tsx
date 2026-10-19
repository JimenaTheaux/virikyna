import React from 'react'
import ReactDOM from 'react-dom/client'
import { HashRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { disableNumberInputScroll } from '@virikyna/shared'
import App from './App'
import { AuthProvider } from './auth/AuthContext'
import { Toaster } from './components/Toaster'
import { AvisoActualizacion } from './components/AvisoActualizacion'
import { buscarActualizacion } from './lib/updater'
import { instalarProteccionVentana } from './lib/proteccionVentana'
import './index.css'

disableNumberInputScroll()
instalarProteccionVentana()
// Busca y descarga en segundo plano; nunca instala ni reinicia sola (ver lib/updater.ts).
void buscarActualizacion()

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
        <AvisoActualizacion />
      </HashRouter>
    </QueryClientProvider>
  </React.StrictMode>,
)
