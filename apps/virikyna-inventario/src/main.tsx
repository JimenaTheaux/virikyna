import React from 'react'
import ReactDOM from 'react-dom/client'
import { createHashRouter, RouterProvider } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { disableNumberInputScroll } from '@virikyna/shared'
import App from './App'
import { AuthProvider } from './auth/AuthContext'
import './index.css'

disableNumberInputScroll()

// Mismos defaults que Virikyna Local y Gestión — lo usa la Carga inicial (packages/shared/lib/cargaInicial.ts).
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      refetchOnWindowFocus: false,
    },
  },
})

// Router "de datos" (en vez de <HashRouter>) para poder usar useBlocker: la carga de factura
// pide confirmación antes de descartar lo cargado al cambiar de pestaña o volver atrás. La ruta
// comodín deja que App siga definiendo sus <Routes> como siempre.
const router = createHashRouter([
  {
    path: '*',
    element: (
      <AuthProvider>
        <App />
      </AuthProvider>
    ),
  },
])

ReactDOM.createRoot(document.getElementById('root') as HTMLElement).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  </React.StrictMode>,
)
