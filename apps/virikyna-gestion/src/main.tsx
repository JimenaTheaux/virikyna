import React from 'react'
import ReactDOM from 'react-dom/client'
import { createHashRouter, RouterProvider } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { disableNumberInputScroll } from '@virikyna/shared'
import App from './App'
import { AuthProvider } from './auth/AuthContext'
import './index.css'

disableNumberInputScroll()

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      refetchOnWindowFocus: false,
    },
  },
})

// Router "de datos" (en vez de <HashRouter>), igual que Inventario, para poder usar useBlocker:
// Atrás del navegador con un formulario con cambios pide confirmación en vez de desmontarlo
// (GuardiaNavegacion, en App). La ruta comodín deja que App siga definiendo sus <Routes>.
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
