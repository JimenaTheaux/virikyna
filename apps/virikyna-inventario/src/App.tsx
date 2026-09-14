import { Navigate, Route, Routes } from 'react-router-dom'
import { AppShell } from './layout/AppShell'
import { RequireAuth } from './auth/AuthContext'
import { LoginPage } from './pages/LoginPage'
import { InventarioPage } from './pages/Inventario/InventarioPage'
import { CargarFacturaPage } from './pages/Facturas/CargarFacturaPage'

// Acceso directo post-login a Inventario (docs/04_modulos_y_funciones.md, módulo 5.1) —
// no hay pantalla de Ventas ni Dashboard acá, esas siguen siendo exclusivas de la Caja.
export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />

      <Route element={<RequireAuth />}>
        <Route element={<AppShell />}>
          <Route path="/" element={<Navigate to="/inventario" replace />} />
          <Route path="/inventario" element={<InventarioPage />} />
          <Route path="/facturas" element={<CargarFacturaPage />} />
        </Route>
      </Route>
    </Routes>
  )
}
