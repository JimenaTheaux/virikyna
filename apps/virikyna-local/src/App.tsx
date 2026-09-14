import { Navigate, Route, Routes } from 'react-router-dom'
import { AppShell } from './layout/AppShell'
import { RequireAuth } from './auth/RequireAuth'
import { RequireRole } from './auth/RequireRole'
import { LoginPage } from './pages/LoginPage'
import { VentasPage } from './pages/VentasPage'
import { FacturacionPage } from './pages/Facturacion/FacturacionPage'
import { InventarioPage } from './pages/Inventario/InventarioPage'
import { ProveedoresPage } from './pages/Proveedores/ProveedoresPage'
import { DashboardPage } from './pages/DashboardPage'
import { ClientesPage } from './pages/Clientes/ClientesPage'
import { ConfiguracionPage } from './pages/ConfiguracionPage'
import { CierreCajaPage } from './pages/CierreCaja/CierreCajaPage'
import { NotasPage } from './pages/Notas/NotasPage'

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />

      <Route element={<RequireAuth />}>
        <Route element={<AppShell />}>
          <Route path="/" element={<Navigate to="/dashboard" replace />} />
          <Route path="/ventas" element={<VentasPage />} />
          <Route path="/facturacion" element={<FacturacionPage />} />
          <Route path="/inventario" element={<InventarioPage />} />
          <Route path="/proveedores" element={<ProveedoresPage />} />
          <Route path="/dashboard" element={<DashboardPage />} />
          <Route path="/clientes" element={<ClientesPage />} />
          <Route path="/cierre-caja" element={<CierreCajaPage />} />
          <Route path="/notas" element={<NotasPage />} />

          <Route element={<RequireRole role="admin" />}>
            <Route path="/configuracion" element={<ConfiguracionPage />} />
          </Route>
        </Route>
      </Route>
    </Routes>
  )
}
