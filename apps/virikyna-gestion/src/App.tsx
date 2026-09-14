import { Navigate, Route, Routes } from 'react-router-dom'
import { AppShell } from './layout/AppShell'
import { RequireAuth } from './auth/RequireAuth'
import { LoginPage } from './pages/LoginPage'
import { DashboardPage } from './pages/DashboardPage'
import { InventarioPage } from './pages/InventarioPage'
import { ProveedoresPage } from './pages/ProveedoresPage'
import { ClientesPage } from './pages/ClientesPage'
import { FacturacionPage } from './pages/Facturacion/FacturacionPage'
import { CajaGestionPage } from './pages/CajaGestionPage'
import { EgresosPage } from './pages/EgresosPage'
import { ConfiguracionPage } from './pages/ConfiguracionPage'
import { HistorialPage } from './pages/HistorialPage'
import { NotasPage } from './pages/Notas/NotasPage'

// Sin ruta /ventas — Virikyna Gestión es todo el CRUD de Admin salvo Ventas/cobro
// (docs/05_stack_tecnico.md, sección 3). El rol se valida en AuthContext, no acá: un cajero
// nunca llega a ver estas rutas porque queda deslogueado antes de tener sesión válida.
export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />

      <Route element={<RequireAuth />}>
        <Route element={<AppShell />}>
          <Route path="/" element={<Navigate to="/dashboard" replace />} />
          <Route path="/dashboard" element={<DashboardPage />} />
          <Route path="/inventario" element={<InventarioPage />} />
          <Route path="/proveedores" element={<ProveedoresPage />} />
          <Route path="/clientes" element={<ClientesPage />} />
          <Route path="/facturacion" element={<FacturacionPage />} />
          <Route path="/caja-gestion" element={<CajaGestionPage />} />
          <Route path="/egresos" element={<EgresosPage />} />
          <Route path="/notas" element={<NotasPage />} />
          <Route path="/historial" element={<HistorialPage />} />
          <Route path="/configuracion" element={<ConfiguracionPage />} />
        </Route>
      </Route>
    </Routes>
  )
}
