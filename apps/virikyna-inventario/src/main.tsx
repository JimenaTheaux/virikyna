import React from 'react'
import ReactDOM from 'react-dom/client'
import { createHashRouter, RouterProvider } from 'react-router-dom'
import { disableNumberInputScroll } from '@virikyna/shared'
import App from './App'
import { AuthProvider } from './auth/AuthContext'
import './index.css'

disableNumberInputScroll()

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
    <RouterProvider router={router} />
  </React.StrictMode>,
)
