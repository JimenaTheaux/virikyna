# Auditoría de funcionalidades — Virikyna (base para Pido Gancho)

> Auditoría de solo lectura, 2026-10-27, rama `lote-oct-2026` (HEAD `5358701` al terminar).
> Durante la auditoría otra sesión commiteó la reserva de emisión de Factura C (`68d686e`,
> `6861ce9`) y la alerta de cambios de precio (`5358701`), y sigue editando los Dashboards de
> Local. Lo marcado **[MIGRACIÓN SIN APLICAR]** ya tiene código commiteado pero su SQL
> todavía no está en producción.
> Convención: "A VERIFICAR" = no se pudo confirmar solo leyendo el código; se cita archivo y línea.

---

## 1. Resumen ejecutivo

1. Monorepo npm workspaces: **3 apps React 18 + Vite + TypeScript** (`apps/*`) y un paquete común `@virikyna/shared` (`packages/shared`). Todas hablan **directo con Supabase**, sin backend propio. Cada escritura de negocio es una RPC `SECURITY DEFINER`.
2. **Virikyna Local**: POS de escritorio con **Tauri v2** (no es PWA). **Virikyna Gestión**: PWA de la dueña, solo admin. **Virikyna Inventario**: PWA de celular con cámara.
3. Roles: solo `admin` y `cajero` (enum `rol_usuario`). No existe un superadmin.
4. **Producto plano, sin variantes**: no tiene talle, color ni categoría, y la marca es texto libre. El `codigo_barras` es **UNIQUE por producto**. El stock va por producto × ubicación (`local` / `deposito`).
5. El stock lo mueven solo las RPC: la venta descuenta en `local`, la devolución lo repone (salvo si el motivo es "defectuoso"), y la factura de compra suma en la ubicación de cada ítem. **La venta no valida stock disponible: el stock puede quedar negativo.**
6. La carga de facturas de compra es el módulo más maduro: borradores en servidor, copiar una factura, NC con devolución de mercadería, pago de contado, actualización de costo/proveedor/márgenes y aviso de comprobante repetido.
7. La cuenta corriente de proveedores tiene aplicaciones de pago por comprobante, notas de crédito, pagos a cuenta y pagos con varios medios (cheques/eCheq).
8. La facturación ARCA (Factura C, WSFEv1) es real y está en producción desde el 26/10. Corre en la Edge Function `arca-emitir-factura`. No hay impresora fiscal: el comprobante sale en PDF 80 mm o JPG y se manda por Gmail o WhatsApp.
9. **No hay modo offline real.** Solo se guardan en `localStorage` los tickets abiertos del POS, los borradores y la carga inicial. Lo que dice `docs/05` sobre PowerSync no está implementado.
10. Para Pido Gancho se puede reutilizar casi todo lo transaccional (POS, devoluciones, clientes, proveedores, egresos, auth/RLS). Lo que **no existe** y es el corazón del rubro: **variantes talle/color, categorías, marcas como entidad y un código compartido entre variantes**.

---

## 2. Los 3 sistemas

| | **Virikyna Local** ("la Caja") | **Virikyna Gestión** | **Virikyna Inventario** |
|---|---|---|---|
| Carpeta | `apps/virikyna-local` | `apps/virikyna-gestion` | `apps/virikyna-inventario` |
| Entry point | `src/main.tsx` → `src/App.tsx` | `src/main.tsx` → `src/App.tsx` | `src/main.tsx` → `src/App.tsx` |
| Propósito | Mostrador: vender, facturar, devoluciones, caja X/Z, compras, clientes | Panel de la dueña: todo el CRUD salvo vender, más Caja Gestión, Egresos, Historial/Auditoría y usuarios | Celular: inventario con cámara, carga de facturas de compra y carga inicial |
| Roles que entran | admin y cajero | **solo admin** (al cajero lo desloguea: `src/auth/AuthContext.tsx:8-13`) | admin y cajero |
| Plataforma | **Desktop Tauri v2** (`src-tauri/tauri.conf.json`, ventana 1280×800 maximizada, mínimo 1024×700). Auto-update por GitHub Releases (`plugins.updater`) | **PWA** (`vite-plugin-pwa`, `registerType: 'autoUpdate'`, `vite.config.ts`) | **PWA** (`vite-plugin-pwa` + `basicSsl` para la cámara en la LAN, `vite.config.ts`) |
| Versión | 0.9.0 (`package.json`, `tauri.conf.json`) | 0.1.0 | 0.1.0 |
| Puerto dev | 1420 | 1440 | 1430 |

### Stack real (de los package.json)

- **Framework**: React 18.3, react-router-dom 6.27, TypeScript 5.6, Vite 5.4, Tailwind 3.4.
- **Datos**: `@supabase/supabase-js` 2.112 y `@tanstack/react-query` 5.104 (React Query se usa en partes: carga inicial, proveedores, dashboard de Gestión; el resto usa `useState` + `useEffect`).
- **Otras**: `lucide-react` (íconos), `jspdf` 4.2 (comprobante PDF), `barcode-detector-api-polyfill` (cámara en Inventario y shared).
- **Tauri (solo Local)**: `@tauri-apps/api`, `plugin-updater`, `plugin-process`, `plugin-shell` (abre Gmail/WhatsApp fuera del WebView). En Rust no hay lógica, solo se registran plugins (`src-tauri/src/lib.rs`).
- **Supabase**: Postgres con RLS y unas 90 RPC. Edge Functions: `admin-usuarios` (alta/blanqueo/desactivación de usuarios con service_role) y `arca-emitir-factura` (WSFEv1 con `@aledj02/afip.js`).
- **Service worker**: solo en Gestión e Inventario, generado por `vite-plugin-pwa` (precache del app shell, autoUpdate). Local no tiene SW.
- **Offline**: no hay base local (ni SQLite ni PowerSync ni IndexedDB; lo confirman los comentarios de `apps/virikyna-gestion/vite.config.ts:6` y `apps/virikyna-inventario/vite.config.ts:6`). Ver módulo "Modo offline".
- **Tests**: `node --test packages/shared/tests/*.test.ts` (9 archivos, solo lógica pura de `packages/shared/lib`). No hay tests de UI ni E2E en el repo.
- **CI**: `.github/workflows/release-virikyna-local.yml` (release del instalador de Local).

### Rutas / pantallas

**Local** (`apps/virikyna-local/src/App.tsx`; menú en `src/layout/AppShell.tsx:27-62`):

| Ruta | Pantalla | Rol |
|---|---|---|
| `/login` | `pages/LoginPage.tsx` | — |
| `/dashboard` | `pages/DashboardPage.tsx` → `Dashboard/AdminDashboard.tsx` o `Dashboard/CajeroDashboard.tsx` | ambos |
| `/ventas` | `pages/VentasPage.tsx` | ambos |
| `/facturacion` | `pages/Facturacion/FacturacionPage.tsx` (pestañas Ventas del día / Facturación / Devoluciones) | ambos |
| `/inventario` | `pages/Inventario/InventarioPage.tsx` | ambos |
| `/carga-inicial` | `pages/CargaInicialPage.tsx` (en el menú solo si la carga está abierta) | ambos |
| `/proveedores` | `pages/Proveedores/ProveedoresPage.tsx` (pestañas Facturas de compra / Proveedores) | ambos |
| `/proveedores/:id` | `pages/Proveedores/ProveedorDetallePage.tsx` (cuenta corriente) | ambos |
| `/clientes` | `pages/Clientes/ClientesPage.tsx` ("Cuentas corrientes") | ambos |
| `/cierre-caja` | `pages/CierreCaja/CierreCajaPage.tsx` | ambos |
| `/notas` | `pages/Notas/NotasPage.tsx` | ambos |
| `/configuracion` | `pages/ConfiguracionPage.tsx` (solo versión y "Buscar actualizaciones") | admin (`RequireRole`) |

**Gestión** (`apps/virikyna-gestion/src/App.tsx`; menú en `src/layout/AppShell.tsx:26-54`): `/dashboard`, `/caja-gestion`, `/inventario`, `/carga-inicial`, `/proveedores`, `/proveedores/:id`, `/clientes`, `/facturacion`, `/egresos`, `/notas`, `/historial`, `/configuracion`. No hay `/ventas` (`App.tsx:19-21`).

**Inventario** (`apps/virikyna-inventario/src/App.tsx`; barra inferior en `src/layout/AppShell.tsx`): `/inventario`, `/facturas` (carga de factura de compra), `/carga-inicial` (solo con la carga abierta) y "Salir".

---

## 3. Funcionalidades por módulo

Estado: **Completo** / **Parcial** / **Stub** / **Sin uso**. "Ambos" = admin y cajero.

### 3.1 Login y roles

| Ítem | Detalle |
|---|---|
| Archivos | `packages/shared/auth/createAuthController.tsx` (una fábrica para las 3 apps); `apps/*/src/auth/AuthContext.*`; `apps/*/src/pages/LoginPage.tsx`; `apps/virikyna-local/src/auth/RequireRole.tsx` |
| Acciones | Login email+password (`signInWithPassword`); "Cambiar de usuario" (signOut, en el header de Local); "Salir" en Inventario |
| Reglas | Después del login se lee `perfiles` (la fila propia). Un perfil inactivo o inexistente se desloguea con un mensaje (`createAuthController.tsx:62-74`). Gestión rechaza al cajero (`validarPerfil`). TOKEN_REFRESHED no vuelve a "Cargando…" para no desmontar formularios (`:34-38`) |
| Roles | Enum `rol_usuario = admin | cajero`. En el front: `RequireRole` (solo `/configuracion` en Local), menú filtrado por rol y `esAdmin` en formularios. En la base: cada RPC valida `perfiles.rol` + `activo` |
| Tablas | `perfiles` (RLS `perfil_propio`: solo la fila propia), vista `perfiles_publico` (id+nombre para todos) |
| Estado | **Completo** |

### 3.2 Configuración / usuarios

| Ítem | Detalle |
|---|---|
| Archivos | Gestión: `pages/ConfiguracionPage.tsx`, `Configuracion/UsuarioFormModal.tsx`, `Configuracion/BlanquearPasswordModal.tsx`, `lib/usuarios.ts`. Edge: `supabase/functions/admin-usuarios/index.ts`. Local: `pages/ConfiguracionPage.tsx` |
| Acciones (Gestión) | Listar usuarios; crear (email, password, nombre, rol); editar nombre/rol; blanquear contraseña; activar/desactivar |
| Acciones (Local) | Ver la versión instalada; "Buscar actualizaciones" (Tauri updater, `lib/updater.ts`). La gestión de usuarios está a propósito solo en Gestión (`ConfiguracionPage.tsx:23-25`) |
| Reglas | Crear, blanquear y desactivar pasan por la Edge Function con service_role (la key no viaja al bundle). Editar y listar por RPC `editar_usuario`, `listar_usuarios`, `set_usuario_activo` |
| Roles | Solo admin |
| Tablas/RPC | `perfiles`, `auth.users`; RPC `listar_usuarios`, `editar_usuario`, `set_usuario_activo`, `listar_admins` |
| Estado | **Completo** (Gestión). No hay "ajustes del negocio" (datos fiscales, punto de venta, etc.): esos datos viven en secretos de la Edge Function |

### 3.3 Dashboard

| Ítem | Detalle |
|---|---|
| Archivos Local | `pages/DashboardPage.tsx`, `Dashboard/AdminDashboard.tsx`, `Dashboard/CajeroDashboard.tsx`, `Dashboard/AbrirCajaCard.tsx`, `Dashboard/WeeklySalesChart.tsx`, `Dashboard/queries.ts` |
| Archivos Gestión | `pages/DashboardPage.tsx`, `Dashboard/{PeriodoFiltro,AperturasAlerta,Reponer,TopProductos,VentasPorMarca,WeeklySalesChart,queries,periodo}.ts(x)`; compartidos `packages/shared/src/components/{StockBajoCard,DefectuososCard}.tsx`, `src/components/dashboard/{ProductosVendidos,ProductosVendidosModal,columnas,ventasPorProducto}.ts(x)` (movidos de Gestión a shared en `5358701`); `dashboard/AlertaPreciosCard.tsx`, `CambiosPrecioModal.tsx`, `preciosCambiados.ts` **[MIGRACIÓN SIN APLICAR: docs/67]**. Los Dashboards de Local tienen cambios en curso de otra sesión |
| Acciones | Local admin: ventas brutas de hoy con el neto de devoluciones, variación contra ayer, tickets, ticket promedio, gráfico de 7 días, stock bajo, defectuosos y accesos rápidos. Local cajero: tarjetas grandes de acceso, ventas del día y stock bajo. Ambos: **abrir caja** (`AbrirCajaCard`, confirma o corrige el monto de apertura). Gestión: período Hoy/Semana/Mes/Rango guardado en la URL; KPIs con comparación contra el período anterior; ventas por día; productos vendidos (un día) o Top productos (unidades/importe); "Reponer"; ventas por marca; alerta de aperturas con diferencia ("marcar revisada"); stock bajo y defectuosos; alerta de cambios de precio con "Etiqueta actualizada" e impresión (`window.print`) **[MIGRACIÓN SIN APLICAR: docs/67]** |
| Reglas | Fechas en hora AR (`hoyAR`). Stock bajo = stock total ≤ `stock_minimo` (con mínimo > 0, docs/64). Las aperturas con diferencia se marcan solo en Gestión |
| Roles | Local: vista distinta por rol. Gestión: admin |
| Tablas/RPC | `ventas`, `devoluciones`, `aperturas_caja`, `cierres_caja`; RPC `dashboard_ventas_por_dia`, `dashboard_ventas_por_producto` (docs/61), `productos_stock_bajo`, `resumen_stock_inventario` (docs/64), `aperturas_con_diferencia_pendientes`, `marcar_apertura_revisada`, `abrir_caja`; docs/67: `alerta_precios_pendientes`, `precios_cambiados`, `marcar_etiquetas` |
| Estado | **Completo** (la alerta de precios queda **Parcial**: el código existe, la migración docs/67 está "⏳ PENDIENTE", `docs/67_alerta_cambio_precios.sql:3`) |

### 3.4 Punto de venta (Ventas)

| Ítem | Detalle |
|---|---|
| Archivos | `apps/virikyna-local/src/pages/VentasPage.tsx`; `Ventas/{ProductoBusqueda,CarritoTabla,ClienteSelector,FormaPagoSelector,PagoCombinadoModal,AjustePorcentajeModal,TicketsBar,ticketsStorage,types}.ts(x)`; `lib/proteccionVentana.ts`; comprobante `components/ComprobanteModal.tsx` → `packages/shared/src/components/ComprobanteModal.tsx`, `packages/shared/lib/{comprobante,comprobantePdf,comprobanteImagen,comprobanteLayout}.ts` |
| Acciones | Buscar producto por nombre, marca o código (parcial, debounce de 200 ms, 8 resultados); **lector de código de barras** (Enter con código exacto lo agrega directo, `ProductoBusqueda.tsx:54-59,130-142`); ↑↓ para elegir; cambiar cantidad; quitar ítem; **hasta 5 tickets en espera** (`ticketsStorage.ts:3`); cliente opcional; forma de pago; **pago combinado de 2 medios**; descuento % y recargo % sobre el total; nota; "Vaciar ticket"; confirmar con un **"Precio final a cobrar" editable** (redondeo manual); comprobante X con envío por Gmail (PDF) o WhatsApp (JPG) |
| Atajos de teclado | Con el foco fuera de los campos: `E` efectivo, `T` transferencia, `Q` QR, `Z` débito, `C` crédito, `D` descuento, `R` recargo, `Enter` cobrar/confirmar, `Esc` cancelar o sacar el foco del buscador. Cualquier otra tecla vuelve al buscador (`VentasPage.tsx:24-31,494-570`). Enter sobre un botón no hace nada (protege del Enter del lector) |
| Reglas | Total = subtotal × (1−desc%) × (1+rec%). La cuenta corriente exige cliente (front + CHECK `chk_venta_cta_cte_requiere_cliente`). El combinado admite como máximo 2 medios y no admite cuenta corriente; la suma de las partes tiene que dar el precio oficial. Si el precio cobrado difiere, el servidor reescala las partes. El precio cobrado tiene que ser > 0. **Idempotencia del cobro**: `client_id` guardado en localStorage antes de llamar a la RPC; al reabrir, los tickets ya cobrados se cierran solos (`VentasPage.tsx:125-152,358-387`, docs/43). No se puede cerrar la ventana mientras se cobra (`proteccionVentana.ts`). El precio unitario es una foto del `precio_venta` |
| Stock | `confirmar_venta` descuenta en `local` (`movimientos_stock` tipo `venta` + `stock_ubicaciones`), **sin validar disponibilidad** (`supabase/schema/schema.sql:1551-1557`). Tampoco exige caja abierta: A VERIFICAR si es intencional (`docs/43_idempotencia_venta.sql:47-180`, no hay chequeo de `aperturas_caja`) |
| Roles | Ambos. No existe en Gestión ni en Inventario |
| Tablas/RPC | `productos` (lectura), `clientes`, `ventas`, `venta_items`, `venta_pagos`, `movimientos_stock`, `stock_ubicaciones`; RPC `confirmar_venta` |
| Estado | **Completo** |

### 3.5 Facturación (ventas del día, Factura C ARCA)

| Ítem | Detalle |
|---|---|
| Archivos | Local `pages/Facturacion/{FacturacionPage,FacturacionTab,VentasDelDiaTab,DevolucionesTab,types}.tsx`; Gestión `pages/Facturacion/{FacturacionPage,FacturacionTab,VentasDelDiaTab,DevolucionesTab,filtroVentas}.ts(x)`; shared `lib/arcaFacturacion.ts`, `lib/confirmacionFacturaC.ts`, `src/components/{ConfirmarFacturaC,VentasDelDiaTab,ItemsVentaFila}.tsx`, `src/components/EmisionesARevisar.tsx`; Edge `supabase/functions/arca-emitir-factura/index.ts` (reserva commiteada en `6861ce9`) **[MIGRACIÓN SIN APLICAR: docs/66]** |
| Acciones | Ventas del día con sus ítems. Facturación: filtros por fecha (por defecto los últimos 30 días), N° de ticket o cliente, estado y medio de pago; selección múltiple; **"Emitir Factura C"** con confirmación (una por venta, en secuencia, `FacturacionTab.tsx:134-147`); ver comprobante/factura; desde una venta, "Devolución / Cambio" (solo Local). Bloqueo de las ventas "a revisar" y desbloqueo por admin **[MIGRACIÓN SIN APLICAR: docs/66]** |
| Reglas | Cobrar y facturar son pasos separados. 1 venta = 1 Factura C, nunca se agrupan. La condición IVA del receptor sale de `clientes.condicion_iva` (RG 5616); sin cliente = Consumidor Final (DocTipo 99). Desde docs/59 las apps mandan siempre `ambiente: produccion`. Una venta con Factura C no se puede anular desde el sistema (`anular_venta`, `schema.sql:562-564`). **No hay Nota de Crédito electrónica** |
| Roles | Ambos emiten. Desbloquear una emisión: admin |
| Tablas/RPC | `ventas`, `venta_pagos`, `facturas_c` (con `ambiente`), `arca_wsaa_tokens`; RPC `emitir_factura_c`, `reemitir_factura_c_produccion` (docs/59); docs/66: `reservar_emision_factura_c`, `listar_emisiones_factura_c_a_revisar`, `desbloquear_emision_factura_c`, tabla `emisiones_factura_c_en_curso` |
| Estado | **Completo** para la emisión. La reserva anti doble-CAE queda **Parcial**: código en curso y migración `docs/66_reserva_emision_factura_c.sql:3` "⏳ SIN APLICAR". A VERIFICAR: qué hace el front con docs/66 sin aplicar (`packages/shared/lib/arcaFacturacion.ts`, modificado) |

### 3.6 Impresora fiscal

No existe. `packages/shared/lib/comprobantePdf.ts:6` dice: "el negocio no tiene impresora fiscal". El comprobante es un PDF de 80 mm (jsPDF) o una imagen JPG para enviar. No hay impresión térmica directa ni ESC/POS. **Estado: no implementado (fuera de alcance)**.

### 3.7 Devoluciones / cambios (y "notas de crédito")

| Ítem | Detalle |
|---|---|
| Archivos | Local `pages/Facturacion/DevolucionModal.tsx`, `pages/Facturacion/DevolucionesTab.tsx`; Gestión `pages/Facturacion/DevolucionesTab.tsx`; shared `lib/devoluciones.ts`, `src/components/{DevolucionesTab,DevolucionDetalleModal,DefectuososCard}.tsx` |
| Acciones | Desde una venta (Local): elegir ítems y cantidades a devolver; motivo (`regalo`, `defectuoso`, `arrepentimiento`, `otro` con detalle); observaciones; **cambio** por productos nuevos (buscador del POS); forma de pago de la diferencia (simple o combinada de 2). Listado de devoluciones con detalle; **anular devolución** (admin). Tarjeta "Defectuosos" en los dashboards |
| Reglas (RPC `crear_devolucion`, `schema.sql:1568-1784`) | Plazo de **15 días** desde la venta (fijo en el código, `:1606-1609`); no se puede sobre una venta anulada; no se devuelve más de lo vendido menos lo ya devuelto, con lock de la venta; el precio devuelto es el efectivamente pagado (importe prorrateado por desc/recargo/precio cobrado); los ítems nuevos van a precio de lista actual; diferencia = nuevos − devueltos: si es > 0 paga el cliente, si es < 0 se le devuelve plata; **la diferencia no puede ir a cuenta corriente** |
| Stock | Devuelto con motivo ≠ defectuoso: +stock en `local` (`movimientos_stock` tipo `ajuste`). **Defectuoso: no reingresa** y queda separado (`reingresa_stock=false`). Nuevos: −stock en `local`. Anular revierte |
| Caja | El neto por medio entra al Cierre (`cierres_caja.total_devoluciones_*`) |
| Notas de crédito | **No hay NC fiscal (ARCA) de venta.** La devolución es un documento interno. Las NC **de compra** existen (módulo 3.12) |
| Roles | Crear: ambos (solo Local). Anular: admin (`anular_devolucion`, `schema.sql:449`) |
| Tablas | `devoluciones`, `devolucion_items`, `devolucion_pagos`, `movimientos_stock`, `stock_ubicaciones` |
| Estado | **Completo**. A VERIFICAR: la vista `clientes_saldo` no descuenta devoluciones de ventas hechas a cuenta corriente (`schema.sql:3213-3234`) |

### 3.8 Inventario y stock (escritorio)

| Ítem | Detalle |
|---|---|
| Archivos | Shared `src/components/inventario/{ProductosTab,FiltrosInventario}.tsx`, `lib/{inventario,estadoStock,precios,useActualizarPrecios,useEliminarProducto,useMarcarIva}.ts`, `src/components/{ActualizarPreciosModal,MarcarIvaModal,InterruptorLlevaIva,NotaRedondeoPrecio,CodigoBarrasBox,ProductoBuscador}.tsx`. Local `pages/Inventario/{InventarioPage,ProductosTab,ProductoFormSheet,AjustarStockSheet,ActualizarPreciosSheet,HistorialPrecioTab}.tsx`. Gestión `pages/InventarioPage.tsx`, `pages/Inventario/{ProductosTab,ProductoFormModal,AjustarStockModal,ActualizarPreciosModal,HistorialPrecioTab}.tsx` |
| Acciones | Listado paginado de a 1000 hasta traer todo (`lib/inventario.ts:43-62`); búsqueda (nombre, marca, código, proveedor; acepta el lector); filtro por estado (activos/inactivos/todos), marca y proveedor; chips de stock (sin stock, bajo, etc.); orden por nombre, precio o stock; filtros en la URL. **Alta** (si no hay código, se genera uno EAN-13 interno), **edición**, **inactivar/reactivar** (baja lógica `estado`), **eliminar** solo admin y solo si no tiene historial (si no, ofrece inactivar; docs/48). **Actualizar precios masivo** por % (selección o por proveedor); **IVA masivo** (21 % / exento, admin); **ajuste manual de stock** por ubicación con motivo (admin); historial de margen (admin, sale de `auditoria`); aviso de código duplicado con "editar el existente" |
| Campos del producto | nombre (se guarda en MAYÚSCULAS por trigger), descripción, código de barras, proveedor, marca (texto), costo, margen 1, margen 2, IVA (21/0), precio manual (cuando no hay costo), stock mínimo, estado. Stock local/depósito: solo lectura en el formulario |
| Reglas de precio | `precio_venta` es **GENERATED**: `COALESCE(precio_manual, redondear_precio_venta(costo×(1+m1)×(1+m2)×(1+iva)))` (`schema.sql:3598`). **Redondeo escalonado** (`schema.sql:2235-2252`): < $500 → centena; < $10.000 → múltiplo de 500 (resto ≤ 200 baja, si no sube); ≥ $10.000 → millar. CHECK: hay costo o hay precio manual. Textos sin acentos (trigger docs/51) |
| Reglas de rol | El cajero carga costo pero **no** margen ni IVA (UI deshabilitada + trigger `fn_proteger_margen_producto`). Ajuste de stock y eliminar: admin. Motivos de ajuste cerrados: `Rotura`, `Perdida`, `Correccion de conteo fisico`, `Otro` (`lib/inventario.ts:76`) |
| Tablas/RPC | `productos` (escritura directa, policy `productos_todos` para cualquier usuario activo, `schema.sql:4712`), `stock_ubicaciones`, `movimientos_stock`, `proveedores`, `auditoria`; RPC `ajustar_stock`, `actualizar_precios_masivo`, `eliminar_producto`, `generar_codigo_interno`, `fijar_iva_productos` / `marcar_iva_productos`, `productos_stock_bajo` |
| Estado | **Completo** |

### 3.9 Inventario desde celular (cámara)

| Ítem | Detalle |
|---|---|
| Archivos | `apps/virikyna-inventario/src/pages/Inventario/{InventarioPage,ProductoFormSheet,AjustarStockSheet,ActualizarPreciosSheet,MarcarIvaSheet}.tsx`, `src/components/BarcodeScanner.tsx` → `packages/shared/src/components/BarcodeScanner.tsx`, `ScanButton.tsx`, `BottomSheet.tsx`, `lib/lecturaCamara.ts`, `lib/productoBusqueda.ts` |
| Acciones | Las mismas que el escritorio, en tarjetas y bottom-sheets: buscar, filtrar, alta, edición, inactivar, precios masivos, IVA (admin), ajuste de stock (admin). **Escanear con la cámara** llena el buscador; si no hay resultados, ofrece crear el producto con ese código (`InventarioPage.tsx:98-110`) |
| Reglas del escáner | API nativa Barcode Detection o el polyfill (ZXing). Formatos: EAN-13/8, UPC-A/E, Code128, Code39, ITF, QR (`BarcodeScanner.tsx:43`). **Pide la misma lectura en 2 cuadros seguidos (3 para ITF/Code39)** y valida el dígito verificador EAN (`:57-74`). Linterna si el equipo la tiene. Equivalencia UPC-A ↔ EAN-13 con 0 adelante (`productoBusqueda.ts:47-66`, SQL `codigo_barras_variantes`) |
| Roles | Ambos; ajuste e IVA solo admin |
| Estado | **Completo**. Hay una causa de fallo de lectura sin confirmar con datos (ver memoria del proyecto) |

### 3.10 Carga inicial de inventario

| Ítem | Detalle |
|---|---|
| Archivos | Shared `src/components/cargaInicial/{CargaInicial,MiCarga,InventarioTotal,comunes}.tsx`, `lib/cargaInicial.ts`; páginas `apps/*/src/pages/CargaInicialPage.tsx` |
| Acciones | Admin abre/cierra la carga (Gestión). Cada usuario escanea o tipea un código: si existe, elige "sumar" o "reemplazar"; si no, lo da de alta (nombre, marca, descripción, precio, cantidad). Borradores propios en el servidor y en localStorage; "Finalizar" aplica todo; resumen total y por usuario |
| Reglas | Idempotencia por `client_id` (docs/34c). Sin código → EAN-13 interno al finalizar. Stock siempre a `local`. Movimiento tipo `inicial`. "Reemplazar" un producto que ya tiene costo no le cambia el precio |
| Tablas/RPC | `configuracion` (fila única), `carga_inicial_items`, `carga_inicial_operaciones`; RPC `carga_inicial_*`, `abrir_carga_inicial`, `cerrar_carga_inicial` |
| Estado | **Completo** (la carga de Virikyna se cerró el 19/10) |

### 3.11 Categorías y marcas

| Ítem | Detalle |
|---|---|
| Categorías | **No existen.** No hay tabla, columna ni UI. El único "categoría" del sistema es `categoria_egreso` (gastos) |
| Marcas | `productos.marca` es **texto libre** (sin tabla ni FK), en mayúsculas por trigger. El filtro y "Ventas por marca" se arman con `DISTINCT` sobre los productos (`inventario/ProductosTab.tsx:90-96`). No hay ABM de marcas ni marcas "oficiales" |
| Estado | Categorías: **no existe**. Marcas: **Parcial** (solo atributo libre) |

### 3.12 Proveedores, facturas de compra, pagos y cuenta corriente

| Ítem | Detalle |
|---|---|
| Archivos | Shared: `src/components/{CargarFacturaCompraModal,ItemFacturaRow,ItemFacturaBusqueda,EditarFacturaCompraModal,AnularFacturaCompraModal,VincularItemFacturaModal,SelectorFacturaCopiaModal,AvisosCopiaFactura,AvisoCambioPrecioFactura,Borradores,ProveedorCuentaCorriente,PagarProveedorModal,AplicarACuentaModal,MediosPagoEditor,FormaPagoConDetalle,ObservacionesProveedor,SelectorAlicuotaIva}.tsx`; `lib/{facturasCompra,totalesCompra,borradores,borradorFactura,useCopiaFacturaCompra,pagosACuenta,repartoPagoProveedor,mediosPago}.ts`. Local: `pages/Proveedores/*`. Gestión: `pages/ProveedoresPage.tsx`, `pages/Proveedores/*`, `CajaGestion/{PendientePagoModal,ProveedorFacturasPendientesModal,ChequesEmitidosModal}.tsx`. Celular: `apps/virikyna-inventario/src/pages/Facturas/{CargarFacturaPage,ItemFacturaRow,SelectorFacturaCopiaSheet}.tsx` |
| ABM proveedores | Alta y edición (razón social, CUIT, dirección, teléfono, mail, contacto, **margen 1 y 2 por defecto**, observaciones). El saldo inicial **no** está en el formulario: se carga una vez en Caja Gestión → Carga inicial y se corrige con motivo (docs/69); **eliminar solo admin y sin historial** (`eliminar_proveedor` + trigger) |
| Carga de factura (punto crítico) | Tipos `factura`, `remito`, `cupon`, `presupuesto`, `nota_credito`, `nota_debito`; letra A/B/R/X; punto de venta y número; fecha y fecha fiscal opcional; **alícuota IVA 21 % o exento** por comprobante; **tipo de compra artículos/servicios** (servicios no toca stock ni costo, cantidad 1); forma de pago `contado` / `cuenta_corriente`. Ítems tipo planilla: buscar o escanear producto por ítem, **crear producto desde el ítem**, "usar el existente" si el código ya está, **ítem libre** sin producto, cantidad, precio unitario sin IVA, % de descuento, **ubicación local/depósito**. Aviso de **comprobante ya cargado** (`existe_comprobante_compra`); aviso de cambio de precio; **copiar factura** (aunque sea de otro proveedor o esté anulada); **borradores en el servidor** con autoguardado, retomables desde las 3 apps (docs/54); **NC con devolución de mercadería** (resta stock y valida que alcance); **pago de contado al guardar** (factura + pago en efectivo + egreso en una transacción, exige caja abierta si sale de la Caja Local, docs/57); después de guardar, ofrece **aplicar pagos a cuenta** |
| Reglas de la RPC `cargar_factura_compra` (`docs/55_nc_stock.sql:59-272`) | Total = Σ cant × precio × (1−desc) + IVA. Stock + por ítem con producto en su ubicación (no en NC). Por producto, con la **última línea**: costo = precio unitario con descuento; si cambia el proveedor, toma el nuevo y sus márgenes por defecto; poner costo **borra el precio manual**. NC y ND no tocan costo. Borrador: se elimina en la misma transacción |
| Edición / anulación | Editar la cabecera (`editar_factura_compra`); **anular** (revierte stock y pagos; en Local no se ofrece, `ProveedorDetallePage.tsx:26`); **vincular un ítem libre a un producto** después de cargado, con vista previa del costo (docs/50, docs/56) |
| Pagos | Desde la cuenta corriente: elegir uno o varios comprobantes con saldo y NC con crédito; reparto simulado (`repartoPagoProveedor.ts`) que la RPC vuelve a validar; sin selección, va a las facturas más viejas y el sobrante queda "a cuenta". **Local: 1 medio** (v2, origen `turno`, entra al cierre). **Gestión: varios medios** (efectivo, transferencia, cheque, eCheq con número, banco y fechas) (v3, origen `general`). Cartera de cheques emitidos. Revertir un pago (Historial). Desaplicar una aplicación (Gestión) |
| Cuenta corriente | KPIs, comprobantes por estado (`pendiente`/`parcial`/`pagada`/`anulada`, calculado en la vista), historial de pagos con lo que cubrió cada uno, pagos a cuenta, filtros en la URL |
| Roles | Casi todo, ambos. Admin: eliminar proveedor. Editar y anular facturas, desaplicar y pagos con varios medios: solo en Gestión (admin) |
| Tablas/RPC | `proveedores`, `facturas_compra`, `facturas_compra_items`, `pagos_proveedor`, `pagos_proveedor_aplicaciones`, `pagos_proveedor_medios`, `egresos`, `borradores`, `productos`, `stock_ubicaciones`, `movimientos_stock`; vistas `proveedores_saldo`, `facturas_compra_saldo`, `pagos_proveedor_a_cuenta`, `proveedores_a_cuenta`, `cartera_cheques_emitidos`; RPC `cargar_factura_compra`, `cargar_factura_compra_contado`, `existe_comprobante_compra`, `editar_factura_compra`, `anular_factura_compra`, `vincular_item_factura_compra`, `vista_previa_vincular_item_factura_compra`, `registrar_pago_proveedor` (v1, delega en v2), `_v2`, `_v3`, `aplicar_pagos_a_cuenta`, `desaplicar_pago`, `eliminar_proveedor` |
| Estado | **Completo** |

### 3.13 Clientes y cuenta corriente de clientes

| Ítem | Detalle |
|---|---|
| Archivos | Local `pages/Clientes/{ClientesPage,ClienteFormModal,ClienteDetalleModal,RegistrarPagoClienteModal}.tsx`, `pages/Ventas/ClienteSelector.tsx`; Gestión `pages/ClientesPage.tsx`, `pages/Clientes/*` (casi duplicados) |
| Acciones | Listado con saldo; alta y edición (razón social o nombre de fantasía, al menos uno; CUIT; domicilio; mail; celular; **condición IVA**). El saldo inicial **no** está en el formulario: se carga una vez en Caja Gestión → Carga inicial y se corrige con motivo (docs/69); **eliminar** (la base lo rechaza si tiene historial, `fn_proteger_eliminacion_cliente`) o **inactivar**; detalle de cuenta corriente (ventas a cta cte + pagos); **registrar un pago** (1 medio, opcionalmente aplicado a una venta) |
| Reglas | Saldo = saldo inicial + ventas a cta cte no anuladas − pagos (vista `clientes_saldo`). El pago no puede ser `cuenta_corriente` ni `combinado` (CHECK) |
| Roles | Ambos |
| Tablas/RPC | `clientes` (escritura directa), `clientes_saldo`, `ventas`, `pagos_cliente`; RPC `registrar_pago_cliente` |
| Estado | **Completo** |

### 3.14 Apertura de caja, Cierre X / Z, retiros y egresos de turno

| Ítem | Detalle |
|---|---|
| Archivos | Local `pages/Dashboard/AbrirCajaCard.tsx`, `pages/CierreCaja/{CierreCajaPage,ConfirmarCierreZModal,CierreDetalleModal,RegistrarEgresoModal,RegistrarRetiroModal}.tsx`, `lib/caja.ts` |
| Acciones | **Abrir caja** (monto esperado = efectivo contado del último Z; se confirma o corrige); **Cierre X** (foto del turno, sin conteo); **Cierre Z** (una vez por día, con efectivo contado → diferencia); ver el detalle de un cierre; **registrar egreso de turno** (categorías agua/descartables/super/otro/pago a proveedor); **retiro de efectivo** hacia un admin (el único camino por el que el efectivo de Local llega a Caja Gestión) |
| Reglas (`cerrar_caja`) | Totales por medio de pago (solo ventas) más el neto de devoluciones; efectivo esperado = apertura + efectivo − egresos en efectivo − retiros ± devoluciones en efectivo; un solo Z por día (índice único); una sola apertura abierta a la vez; el Z cierra la apertura; el Z queda `pendiente_validacion` hasta que lo valida un admin en Gestión |
| Roles | Ambos |
| Tablas/RPC | `aperturas_caja`, `cierres_caja`, `egresos`, `retiros_caja`, `movimientos_cuenta`; RPC `abrir_caja`, `cerrar_caja`, `registrar_egreso_general` (origen `turno`), `registrar_retiro_caja`, `registrar_pago_proveedor_v2`, `listar_admins` |
| Estado | **Completo** |

### 3.15 Caja Gestión (tesorería de la dueña)

| Ítem | Detalle |
|---|---|
| Archivos | Gestión `pages/CajaGestionPage.tsx`, `CajaGestion/{ResumenCuentasTab,TableroTab,CargaInicialTab,MovimientosManualesTab,EditarMovimientoModal,PendienteCobroModal,PendientePagoModal,ProveedorFacturasPendientesModal,ChequesEmitidosModal}.tsx`, `lib/caja.ts` |
| Acciones | Saldo por cuenta (Efectivo, bancos, etc.), por cobrar (clientes), por pagar (proveedores), cheques emitidos; **tablero de cierres** y **validar Cierre Z**; **carga inicial de saldos** (cuentas, proveedores, clientes; único por cuenta, estado por fila y corrección con motivo, docs/69); **movimientos manuales** (ingreso/egreso), **transferencia entre cuentas**, editar o eliminar un movimiento (con contra-asiento) |
| Reglas | El saldo de cada cuenta es la suma de `movimientos_cuenta`. Nada se pisa: las correcciones son contra-asientos. El efectivo de Local no impacta Efectivo de Gestión salvo por retiros (docs/58) |
| Roles | Admin (solo existe en Gestión; RLS `cuentas_solo_admin`) |
| Tablas/RPC | `cuentas`, `cuenta_forma_pago`, `movimientos_cuenta`, `cuentas_saldo`, `cierres_caja`; RPC `validar_cierre_z`, `cargar_saldos_iniciales`, `registrar_movimiento_caja_general`, `transferir_entre_cuentas`, `editar_movimiento_cuenta`, `eliminar_movimiento_cuenta` |
| Estado | **Completo** |

### 3.16 Egresos (generales)

| Ítem | Detalle |
|---|---|
| Archivos | Gestión `pages/EgresosPage.tsx`, `Egresos/{RegistrarEgresoTab,HistorialEgresosTab,types}.ts(x)`; shared `lib/egresoTexto.ts`, `registrarEgresoGeneral` en `lib/facturasCompra.ts` |
| Acciones | Registrar un egreso general (categoría `sueldo`/`servicio`/`otro`, monto, descripción, forma de pago efectivo/transferencia/cheque/eCheq, **fecha editable**); historial unificado (generales + de turno) con filtro de origen y rango por fecha real |
| Reglas | Origen siempre `general` en Gestión. Las categorías son un **enum** de la base. Un egreso de "pago a proveedor" se revierte desde su pago |
| Roles | Admin (Gestión); el egreso de turno lo hacen ambos desde Local (3.14) |
| Tablas/RPC | `egresos`, `movimientos_cuenta`; RPC `registrar_egreso_general` |
| Estado | **Completo** |

### 3.17 Historial y auditoría

| Ítem | Detalle |
|---|---|
| Archivos | Gestión `pages/HistorialPage.tsx`, `Historial/{DetalleAuditoriaModal,NotaCorreccionModal,types}.tsx`, `lib/historial.ts` |
| Acciones | Listado de `auditoria` (alta, edición, eliminación, anulación, reversión, nota) con filtros; detalle antes/después; **revertir** alta, edición o movimiento según reglas (`lib/historial.ts:107-160`); **anular venta** (sin Factura C); nota de corrección sobre un cierre; marca "Registro eliminado" |
| Reglas | Trigger genérico `fn_auditoria_generica` en casi todas las tablas (`schema.sql:4076-4144`). Una venta facturada no se revierte. El ajuste de stock se revierte solo si es manual |
| Roles | Admin (RLS `auditoria_select_solo_admin`) |
| Estado | **Completo** |

### 3.18 Notas internas

`packages/shared/src/components/notas/{NotasInternas,NuevaNotaModal}.tsx`; páginas `apps/{local,gestion}/src/pages/Notas/NotasPage.tsx`. Post-its con hilos de respuestas, editar (solo el autor) y archivar el hilo. Separadas por `origen` (`local` / `gestion`, reforzado por RLS). Tablas `notas_internas`, vista `notas_internas_con_autor`; RPC `editar_nota`, `archivar_nota`. **Completo.**

### 3.19 Modo offline / sincronización

| Ítem | Detalle |
|---|---|
| Lo que hay | Indicador de conexión en Local (`components/ConnectionStatus.tsx`, `hooks/useOnlineStatus.ts` con `navigator.onLine`). **Tickets abiertos del POS** en `localStorage` (`Ventas/ticketsStorage.ts`): sobreviven a un cierre o corte de luz. Idempotencia del cobro (docs/43). **Borradores de factura**: copia local y servidor (`lib/borradores.ts`). Carga inicial: filas pendientes en `localStorage` (`lib/cargaInicial.ts:334-347`). Mensajes "Sin conexión" diferenciados (`lib/supabaseErrors.ts`). PWA: precache del app shell |
| Lo que no hay | **No se puede vender, buscar productos ni cargar nada sin internet.** No hay cola de escrituras, base local ni sincronización. PowerSync figura en `docs/05` y en las skills pero **no está implementado** |
| Estado | **Parcial / no implementado** (resiliencia, no offline) |

### 3.20 Otros transversales

- **Actualización de la app**: Local con Tauri updater y aviso "Reiniciar ahora" (`components/AvisoActualizacion.tsx`, `lib/updater.ts`); PWAs con autoUpdate.
- **Guardia de cambios sin guardar**: `GuardiaNavegacion`, `lib/cambiosSinGuardar.ts`, modales que piden confirmación.
- **Header `x-virikyna-app`** para saber desde qué app viene una llamada (borradores, `app_cliente()`, docs/54).
- **Envío del comprobante**: Gmail web (descarga el PDF) o WhatsApp (`wa.me`, descarga el JPG); no hay adjunto automático.

---

## 4. Modelo de datos

Fuentes: `supabase/schema/schema.sql` (dump del **2026-10-08**, desactualizado), migraciones `docs/NN_*.sql` posteriores y `packages/shared/types/database.ts` (mantenido a mano, al día al 27/10). Aplicadas hasta docs/65; **docs/66 y docs/67 sin aplicar**.

### 4.1 Enums

| Enum | Valores |
|---|---|
| `rol_usuario` | admin, cajero |
| `estado_producto` | activo, inactivo |
| `ubicacion_stock` | local, deposito |
| `tipo_movimiento_stock` | venta, compra, ajuste, inicial |
| `forma_pago_venta` | efectivo, transferencia, qr, tarjeta_debito, tarjeta_credito, cuenta_corriente, combinado |
| `estado_comprobante` (venta) | sin_facturar, facturado, anulada |
| `motivo_devolucion` | regalo, defectuoso, arrepentimiento, otro |
| `estado_devolucion` / `tipo_item_devolucion` | activa, anulada / devuelto, nuevo |
| `tipo_comprobante_compra` | factura, remito, cupon, nota_credito, nota_debito, presupuesto |
| `letra_comprobante_compra` | A, B, R, X |
| `forma_pago_compra` | contado, cuenta_corriente |
| `forma_pago_egreso` | efectivo, transferencia, cheque, echeq, **mixto** (docs/65) |
| `origen_egreso` | turno, general |
| `categoria_egreso` | pago_proveedor, sueldo, servicio, otro, agua, descartables, super |
| `condicion_iva_cliente` | consumidor_final, responsable_inscripto, monotributista, exento, no_categorizado |
| `tipo_cierre` / `estado_cierre_z` | x, z / pendiente_validacion, validado |
| `tipo_movimiento_cuenta` | saldo_inicial, venta, pago_cliente, pago_proveedor, egreso, ingreso_manual, cierre_z, transferencia_interna, retiro |
| `tipo_accion_auditoria` | alta, edicion, eliminacion, anulacion, reversion, nota_correccion |
| Textos con CHECK (no enum) | `facturas_compra.tipo_compra` (articulos/servicios), `borradores.tipo` (factura_compra), `borradores.sistema` (local/gestion/inventario), `notas_internas.origen` (local/gestion), `facturas_c.ambiente` (homologacion/produccion), `productos_precios_historial.origen` |

### 4.2 Tablas

| Tabla | Columnas clave | FKs / restricciones |
|---|---|---|
| `perfiles` | id, nombre, rol, activo, created_at | id → auth.users |
| `productos` | id, nombre, descripcion, codigo_barras, codigo_interno, proveedor_id, marca (text), costo, margen_1, margen_2, iva_porcentaje, precio_manual, **precio_calculado (GEN)**, **precio_venta (GEN)**, stock_minimo, estado, created_at, updated_at | **UNIQUE codigo_barras**, UNIQUE codigo_interno, proveedor_id → proveedores; CHECK costo o precio_manual; precio_manual > 0 |
| `stock_ubicaciones` | id, producto_id, ubicacion, cantidad numeric(10,2) | UNIQUE (producto_id, ubicacion); → productos ON DELETE CASCADE |
| `movimientos_stock` | id, producto_id, ubicacion, tipo, cantidad (±), motivo, referencia_id, usuario_id, created_at | → productos, perfiles |
| `proveedores` | id, razon_social, cuit, direccion, telefono, mail, contacto, margen_1_default, margen_2_default, saldo_inicial, saldo_inicial_fecha, saldo_inicial_usuario_id, observaciones | saldo inicial solo admin (trigger, docs/69) |
| `clientes` | id, razon_social, nombre_fantasia, cuit, domicilio, mail, celular, activo, saldo_inicial, saldo_inicial_fecha, saldo_inicial_usuario_id, condicion_iva | CHECK al menos un nombre; saldo inicial solo admin (trigger, docs/69) |
| `ventas` | id, numero (bigint), cliente_id, forma_pago, subtotal, descuento_porcentaje, recargo_porcentaje, total, precio_oficial, precio_cobrado, estado, nota, terminal_id (default 'POS001'), usuario_id, **client_id** (UNIQUE parcial), created_at | → clientes, perfiles; CHECK cta cte con cliente; precio_cobrado > 0 |
| `venta_items` | id, venta_id, producto_id, cantidad, precio_unitario, descuento_porcentaje, importe, producto_nombre, producto_marca (snapshot) | → ventas CASCADE, productos |
| `venta_pagos` | id, venta_id, forma_pago, monto, usuario_id | → ventas CASCADE |
| `facturas_c` | id, venta_id (UNIQUE), cae, numero_factura, punto_venta, fecha_emision, pdf_url, enviado_a, usuario_id, ambiente | → ventas |
| `devoluciones` | id, numero, venta_id, fecha, usuario_id, motivo, motivo_detalle, observaciones, diferencia_monto, diferencia_forma_pago, estado, anulada_por/at, motivo_anulacion | → ventas, perfiles |
| `devolucion_items` | id, devolucion_id, tipo, producto_id, cantidad > 0, precio_unitario ≥ 0, reingresa_stock, producto_nombre, producto_marca | → devoluciones CASCADE, productos |
| `devolucion_pagos` | id, devolucion_id, forma_pago, monto | → devoluciones CASCADE |
| `facturas_compra` | id, proveedor_id, tipo_comprobante, letra, punto_venta, numero_comprobante, fecha_comprobante, fecha_fiscal, forma_pago, total_sin_iva, iva, total, iva_alicuota (0/21), tipo_compra, devuelve_mercaderia, anulada, copiada_de_id, usuario_id | → proveedores, perfiles, self |
| `facturas_compra_items` | id, factura_compra_id, producto_id (null = ítem libre), descripcion, cantidad, precio_unitario_sin_iva, descuento_porcentaje, precio_total_sin_iva, ubicacion | → facturas_compra CASCADE, productos |
| `pagos_proveedor` | id, proveedor_id, factura_compra_id (DEPRECATED), monto, forma_pago, cheque_*, fecha, nota, revierte_pago_proveedor_id, usuario_id | → proveedores, facturas_compra, self |
| `pagos_proveedor_medios` (docs/65) | id, pago_proveedor_id, medio, monto, numero, banco, fecha_salida, fecha_pago, propio, orden, revierte_medio_id | → pagos_proveedor |
| `pagos_proveedor_aplicaciones` | id, factura_compra_id, monto, pago_proveedor_id \| nota_credito_id, operacion_id, revertida_at/por | → facturas_compra, pagos_proveedor |
| `pagos_cliente` | id, cliente_id, venta_id, monto, forma_pago, revierte_pago_cliente_id, usuario_id | → clientes, ventas; CHECK sin cta cte/combinado |
| `aperturas_caja` | id, cierre_z_previo_id, monto_esperado, monto_real, diferencia, cierre_z_id, usuario_id, abierta_at, revisada_por/at | UNIQUE parcial: una abierta |
| `cierres_caja` | id, tipo, turno_fecha, total_efectivo/transferencia/qr/tarjeta/cuenta_corriente, total_egresos, total_retiros, efectivo_esperado, efectivo_contado, diferencia, estado_validacion, validado_por/at, apertura_id, cantidad_devoluciones, total_devoluciones_* | UNIQUE parcial: un Z por día |
| `egresos` | id, cierre_caja_id, origen, categoria, monto, descripcion, forma_pago, fecha, pago_proveedor_id, pago_proveedor_medio_id, revierte_egreso_id, usuario_id | → cierres_caja, pagos_proveedor |
| `retiros_caja` | id, fecha, monto > 0, admin_receptor_id, cajero_id, movimiento_cuenta_id, usuario_id | → perfiles, movimientos_cuenta |
| `cuentas` / `cuenta_forma_pago` / `movimientos_cuenta` | cuentas (nombre UNIQUE); forma_pago → cuenta; movimientos (cuenta_id, tipo, monto ±, descripcion, referencia_id, revierte_movimiento_id) | UNIQUE saldo_inicial por cuenta |
| `auditoria` | id, tabla_afectada, registro_id, accion, valores_anteriores/nuevos (jsonb), usuario_id, revierte_auditoria_id, nota | — |
| `notas_internas` | id, mensaje, autor_id, origen, parent_id, archivada, archivada_at/por, editada_at | → perfiles, self |
| `borradores` (docs/54) | id, tipo, sistema, payload jsonb (≤ 500 KB), resumen, usuario_id, actualizado_por, version | — |
| `configuracion` | fila única: carga_inicial_abierta, abierta/cerrada_at/por, datos_reset_at | — |
| `carga_inicial_items` / `carga_inicial_operaciones` | borradores de carga inicial por usuario / idempotencia | UNIQUE (usuario, codigo) |
| `arca_wsaa_tokens` | caché del ticket WSAA | — |
| `emisiones_factura_c_en_curso` (docs/66, **sin aplicar**) | reserva de emisión por venta | — |
| `productos_precios_historial`, `productos_etiqueta` (docs/67, **sin aplicar**) | historial de precio con origen; precio impreso en la etiqueta | → productos |

**Vistas**: `clientes_saldo`, `proveedores_saldo`, `facturas_compra_saldo` (estado y saldo calculados), `cuentas_saldo`, `perfiles_publico`, `notas_internas_con_autor`, `pagos_proveedor_a_cuenta`, `proveedores_a_cuenta`, `cartera_cheques_emitidos`. Todas con `security_invoker`, salvo las indicadas en docs.

### 4.3 RLS y policies

- **anon**: sin acceso a nada del schema `public` (`docs/38_seguridad_prelanzamiento.sql:133-142`).
- **Usuario activo (admin o cajero)**: SELECT en casi todo. **Escritura directa solo en** `productos` (`productos_todos`, todas las operaciones; el DELETE se quitó en docs/48), `clientes` (`clientes_todos`), `proveedores` (insert/update; delete solo admin) y `notas_internas` (filtrado por origen).
- **Tablas operativas de solo lectura** (escritura solo vía RPC): ventas, venta_items, venta_pagos, stock_ubicaciones, facturas_c, facturas_compra(_items), pagos_cliente, pagos_proveedor(_aplicaciones), egresos, retiros_caja (`docs/38:56-101`, `docs/02_roles_y_permisos.md:60`).
- **Solo admin**: `auditoria` (SELECT), `cuentas`, `cuenta_forma_pago`, `movimientos_cuenta`, UPDATE de `cierres_caja` (validar).
- **Propias**: `perfiles` (fila propia), `carga_inicial_items` y `_operaciones` (por usuario).
- Las restricciones de rol también se validan **dentro de cada RPC** (doble capa, `docs/02:62-64`). El margen y el IVA se protegen con un trigger, no con RLS.

### 4.4 Funciones RPC y triggers (por área)

- **Venta/caja**: `confirmar_venta`, `anular_venta`, `crear_devolucion`, `anular_devolucion`, `abrir_caja`, `cerrar_caja`, `validar_cierre_z`, `marcar_apertura_revisada`, `aperturas_con_diferencia_pendientes`, `registrar_retiro_caja`, `registrar_egreso_general` (2 sobrecargas), `registrar_pago_cliente`.
- **ARCA**: `emitir_factura_c`, `reemitir_factura_c_produccion`; docs/66: `reservar_/liberar_/marcar_revisar_/desbloquear_emision_factura_c`, `listar_emisiones_factura_c_a_revisar`, `registrar_ultimo_arca_emision_factura_c`.
- **Productos/stock**: `ajustar_stock`, `actualizar_precios_masivo`, `eliminar_producto`, `generar_codigo_interno`, `ean13_digito_verificador`, `codigo_barras_variantes`, `redondear_precio_venta`, `marcar_iva_productos`, `fijar_iva_productos`, `productos_stock_bajo`, `resumen_stock_inventario`, `quitar_acentos`.
- **Compras/proveedores**: `cargar_factura_compra`, `cargar_factura_compra_contado`, `existe_comprobante_compra`, `editar_factura_compra`, `anular_factura_compra`, `vincular_item_factura_compra`, `vista_previa_vincular_item_factura_compra`, `plan_costo_vinculo_item`, `aplicar_costo_vinculo_item`, `registrar_pago_proveedor` (v1/v2/v3), `aplicar_pagos_a_cuenta`, `desaplicar_pago`, `eliminar_proveedor`.
- **Tesorería**: `cargar_saldos_iniciales`, `registrar_movimiento_caja_general`, `transferir_entre_cuentas`, `editar_movimiento_cuenta`, `eliminar_movimiento_cuenta`.
- **Auditoría**: `revertir_alta`, `revertir_edicion`, `revertir_movimiento`, `agregar_nota_correccion`.
- **Usuarios**: `listar_usuarios`, `listar_admins`, `editar_usuario`, `set_usuario_activo`.
- **Dashboard**: `dashboard_ventas_por_dia`, `dashboard_ventas_por_producto`; docs/67: `alerta_precios_pendientes`, `precios_cambiados`, `marcar_etiquetas`.
- **Carga inicial**: `carga_inicial_{buscar_codigo,guardar_item,editar_producto,eliminar_item,finalizar,resumen,producto_por_codigo,reclamar_operacion,verificar_acceso}`, `abrir_carga_inicial`, `cerrar_carga_inicial`.
- **Notas**: `editar_nota`, `archivar_nota`, `nota_visible_para_mi`. **Otros**: `app_cliente`.
- **Triggers**: `trg_auditoria_*` (genérico, en unas 20 tablas); `trg_proteger_eliminacion_cliente` / `_proveedor`; `trg_proteger_margen_producto` / `_proveedor`; `trg_proteger_alta_producto` (docs/48); `trg_normalizar_texto_producto` (mayúsculas), `trg_normalizar_descripcion_item_libre`; `trg_sin_acentos` (unas 17 tablas, docs/51); `trg_proteger_tipo_compra`; `trg_borradores_mantener`; `trg_notas_internas_guardia` / `_archivar_hilo`; docs/67: `trg_precio_historial_upd/ins`.

### 4.5 Modelo de PRODUCTO (detalle)

- **¿Soporta variantes (talle/color)?** **No.** `productos` es una tabla plana sin `talle`, `color`, `producto_padre_id` ni tabla de variantes (`schema.sql:3586-3607`; `types/database.ts:154-173`). Nada en el código las menciona.
- **¿Código de barras por producto o por variante?** **Por producto, y único**: `productos_codigo_barras_key UNIQUE (codigo_barras)` (`schema.sql:3875-3876`). Dos productos no pueden compartir código. El POS resuelve el Enter del lector buscando **un** producto activo con ese código exacto; si hay más de uno, no elige (`ProductoBusqueda.tsx:24-39`). Se toleran variantes de escritura del **mismo** código (UPC-A ↔ EAN-13 con 0), no códigos compartidos.
- **¿Código interno generado?** **Sí.** `generar_codigo_interno()`: `'20'` + secuencia de 10 dígitos (`codigo_interno_seq`) + dígito verificador EAN-13, chequeado contra `productos` y `carga_inicial_items` (`schema.sql:2111-2132`). Desde docs/49 las 3 apps lo usan en un alta sin código y **lo guardan en `codigo_barras`** (escaneable). La columna `codigo_interno` quedó para los códigos viejos `INT-…` del generador JS (`docs/49_codigo_interno_apps.sql:7-17`).
- **Precio**: `precio_venta` GENERATED con fórmula costo × márgenes × IVA, redondeo escalonado, y precio manual que tiene prioridad (ver 3.8). El costo lo actualiza la última factura de compra.
- **Stock**: `stock_ubicaciones` (producto × `local`/`deposito`), numeric(10,2) (admite fracciones), con libro en `movimientos_stock`. Stock total = suma de ubicaciones.
- **Al vender**: `confirmar_venta` inserta `movimientos_stock(tipo='venta', ubicacion='local', cantidad=−n)` y hace upsert en `stock_ubicaciones` restando. **No valida stock: puede quedar negativo.** Siempre descuenta de `local` (`schema.sql:1551-1557`).
- **Al devolver**: `crear_devolucion` repone en `local` con `tipo='ajuste'` y motivo "Devolución de venta #N", **salvo motivo `defectuoso`** (no reingresa; queda en `devolucion_items.reingresa_stock=false`). Los ítems del cambio descuentan en `local` (`schema.sql:1746-1780`). Anular la devolución revierte ambos. Anular la venta repone todo (`schema.sql:566-575`).
- **Al comprar**: + en la ubicación del ítem (`compra`); una NC con devolución de mercadería resta (`ajuste`) validando que alcance; una NC sin marcar no toca el stock (`docs/55_nc_stock.sql:193-214`).

---

## 5. Matriz de reutilización para Pido Gancho

### 5.1 Requisitos

| Requisito Pido Gancho | Clasificación | Qué existe / qué ajustar |
|---|---|---|
| 1 local | **TAL CUAL** | El modelo ya es mono-sucursal (`local` + `deposito`). `terminal_id` fijo 'POS001' y "Terminal #001" en el código (`apps/virikyna-local/src/layout/AppShell.tsx:138`) |
| PWA instalable en Windows | **CON AJUSTES** | El POS (Local) es **Tauri**, no PWA. Gestión e Inventario ya son PWA. Para el POS como PWA: agregar `vite-plugin-pwa` y reemplazar lo propio de Tauri: updater (`lib/updater.ts`, `components/AvisoActualizacion.tsx`, `ConfiguracionPage`), `plugin-shell` para abrir Gmail/WhatsApp (`components/ComprobanteModal.tsx`), `proteccionVentana.ts` (cierre de ventana → `beforeunload`), `getVersion`. Probablemente convenga **fusionar Local + Gestión en una sola PWA por rol** |
| Rol superadmin (desarrolladora) | **NO EXISTE** | Enum `rol_usuario` = admin/cajero. Habría que agregar el valor y revisar cada policy y RPC que compara `rol = 'admin'` (unas 30 RPC). Ojo: `ALTER TYPE … ADD VALUE` no se puede probar con ROLLBACK |
| 1 admin + 3 vendedores | **CON AJUSTES** | "cajero" = vendedor (renombrar textos). Hoy el cajero puede hacer casi todo salvo las 7 excepciones de `docs/02_roles_y_permisos.md:47-55`. Revisar si los vendedores deben cargar facturas de compra, pagar proveedores o ver costos (hoy sí pueden) |
| POS con lector de código de barras | **TAL CUAL** (lector) / **CON AJUSTES** (variantes) | Buscador, Enter con código exacto, atajos, tickets en espera, combinado, idempotencia: todo reutilizable. Hay que adaptarlo a variantes: si un código es compartido por varios talles/colores, el Enter hoy **no elige** (`ProductoBusqueda.tsx:35-38`); habría que mostrar un selector de variante |
| Devoluciones | **CON AJUSTES** | `crear_devolucion` sirve tal cual si cada variante es una fila vendible. Ajustar: plazo de 15 días fijo (`schema.sql:1606-1609`), motivos (en ropa infantil "cambio de talle" es el caso típico; hoy cae en `otro`/`regalo`), y decidir si el saldo a favor puede quedar en la cuenta corriente del cliente (hoy no) |
| Inventario: categorías | **NO EXISTE** | Falta la tabla `categorias` (¿jerárquica?), FK en producto, filtro en inventario y dashboard |
| Marcas (3 oficiales + otras) | **CON AJUSTES** | Hoy `marca` es texto libre. Crear la tabla `marcas` (con flag `oficial`) + FK, migrar el texto, adaptar `SelectBuscable` y "Ventas por marca" (`apps/virikyna-gestion/src/pages/Dashboard/VentasPorMarca.tsx`) |
| Código de barras | **TAL CUAL** | Escaneo (lector y cámara), equivalencias UPC/EAN y generador EAN-13 interno con prefijo 20 |
| Productos únicos con talle/color | **NO EXISTE** | Hace falta un modelo de variantes. Opción natural: **producto (modelo) + variante (talle, color, código, stock)**, donde la variante pasa a ser lo que hoy es `productos` para venta y stock |
| Productos con **mismo código** y distintos talles/colores | **NO EXISTE (choca con el modelo)** | `UNIQUE(codigo_barras)` lo impide. Hay que sacar el UNIQUE a nivel modelo o mover el código al "modelo" con un selector de talle/color en el POS, la cámara, la carga de factura y la carga inicial. Afecta `resolverCodigoBarras` (`packages/shared/lib/productoBusqueda.ts:87-114`), `buscarPorCodigoExacto`, `existe`/"usar existente" en factura (`ItemFacturaBusqueda.tsx`) y `carga_inicial_*` |
| Stock por variante | **CON AJUSTES** | `stock_ubicaciones` + `movimientos_stock` sirven si se reapuntan a la variante (FK `producto_id` → `variante_id`). Todas las RPC de stock cambian de FK |
| Dashboard (productos y ventas) | **CON AJUSTES** | El dashboard de Gestión (período, comparación, top productos, por marca, reponer, stock bajo) es reutilizable. Faltan cortes por categoría, talle y color, y `dashboard_ventas_por_producto` debería agrupar por modelo o variante |
| Facturación ARCA: no ahora, BD preparada | **TAL CUAL (dejar inactivo)** | `ventas.estado` (sin_facturar/facturado), `facturas_c`, `clientes.condicion_iva`, `arca_wsaa_tokens`, la Edge Function y `emitir_factura_c` existen. Basta con ocultar la pestaña y no desplegar la función. Está pensado para monotributo (Factura C): si Pido Gancho es RI necesita A/B (no existe). Tener en cuenta el incidente de homologación (docs/60) y la reserva docs/66 |
| Proveedores con carga de facturas (crítico) | **CON AJUSTES** | Es lo más reutilizable y probado: planilla, lector por ítem, alta desde el ítem, copia, borradores, NC, contado, cuenta corriente, pagos, aplicaciones. Ajustes: (a) el ítem tiene que apuntar a la **variante** y permitir cargar una **curva de talles** sin una fila por talle; (b) el costo por variante o por modelo hay que decidirlo; (c) alícuota solo 21/0 (`docs/45`), revisar 10,5; (d) fórmula de precio con **redondeo escalonado propio de Virikyna** (`schema.sql:2235-2252`) y 2 márgenes: parametrizar |
| Egresos | **CON AJUSTES** | El flujo sirve tal cual. Las categorías son un **enum** con valores de Virikyna (`agua`, `descartables`, `super`): conviene pasarlas a una tabla editable |
| ABM clientes + cuenta corriente | **TAL CUAL** | Alta, edición, baja/inactivación, saldo por vista, pagos y venta a cuenta corriente. Revisar el punto A VERIFICAR de devoluciones sobre ventas a cuenta corriente (3.7) |

### 5.2 Existe en Virikyna pero NO aplica (o no hace falta en fase 1) para Pido Gancho

- **Tauri** (instalador, updater por GitHub, `src-tauri/`, workflow de release) si se va a PWA.
- **Emisión de Factura C real** y sus parches: docs/59, docs/60 (incidente de homologación), docs/66, `scripts/reemitir-facturas-c.ts`, `scripts/chequear-huerfanos-factura-c.ts`.
- **Caja Gestión** completa (cuentas bancarias, transferencias internas, saldos iniciales, validación de Z por la dueña, retiros a admin): evaluar; para un local chico puede alcanzar con apertura/X/Z.
- **Pagos a proveedor con cheques/eCheq** y cartera de cheques (docs/15, docs/65), salvo que el local pague con cheques.
- **Compras de servicios** (`tipo_compra='servicios'`, docs/53).
- **Carga inicial** colaborativa: útil para arrancar el inventario, pero hay que adaptarla a variantes.
- **Correcciones de datos de Virikyna**: docs/18, 36, 46, 63 (FAYDI), 62 (IVA exentos), reseteos.
- **Redondeo escalonado** y las reglas de precio de Virikyna (márgenes 1 y 2 heredados del proveedor).
- **Notas internas** separadas por app (local/gestion), si hay una sola app.
- **App de celular separada** (Inventario): con una PWA única por rol, la cámara puede vivir en la misma app.
- **Borradores con `sistema`** local/gestion/inventario y el header `x-virikyna-app`.
- **Alerta de cambios de precio / etiquetas** (docs/67): puede servir en ropa (reetiquetado), pero no está aplicada.

---

## 6. Deuda técnica / cosas a medio hacer (solo listado)

1. `supabase/schema/schema.sql` es un dump del **2026-10-08**: no incluye docs/42 a docs/65 (iva_alicuota, tipo_compra, borradores, pagos_proveedor_medios, client_id de venta, etc.). La fuente real es la suma de migraciones en `docs/` más la base.
2. `packages/shared/types/database.ts` se mantiene **a mano** (`:1-3`); no hay `supabase gen types`.
3. Migraciones en `docs/` con numeración que choca: dos `13_*` (`13_categorias_egresos_local.sql`, `13_margen_por_proveedor.sql`), `34`/`34b`/`34c`/`34d`, un `66` renombrado a `67` y un `66` nuevo. No hay carpeta `supabase/migrations` ni registro de cuáles se aplicaron (solo el encabezado ✅/⏳ de cada archivo).
4. **docs/66** (reserva de emisión de Factura C) "⏳ SIN APLICAR" en producción (`docs/66_reserva_emision_factura_c.sql:3`), pero el front y la Edge Function que la usan ya están commiteados (`6861ce9`). A VERIFICAR qué pasa si se despliega la función o el front antes que la migración.
5. **docs/67** (historial de precios y etiquetas) "⏳ PENDIENTE" (`docs/67_alerta_cambio_precios.sql:3`), pero las cards del Dashboard que la usan (`AlertaPreciosCard`, `CambiosPrecioModal`) ya están commiteadas (`5358701`).
6. La venta **no valida stock** (puede quedar negativo) ni exige caja abierta: A VERIFICAR si es decisión de negocio (`schema.sql:1551-1557`; `docs/43_idempotencia_venta.sql`).
7. `clientes_saldo` no considera devoluciones sobre ventas a cuenta corriente: A VERIFICAR (`schema.sql:3213-3234`).
8. **No hay NC electrónica** de venta: una venta con Factura C no se puede anular desde el sistema (`schema.sql:562-564`, "límite conocido de Fase 1").
9. Plazo de devolución de 15 días fijo en la RPC (`schema.sql:1606-1609`); no es configurable.
10. Pago a proveedor en 3 versiones conviviendo (`registrar_pago_proveedor` v1 → v2, v2, v3). `pagos_proveedor.factura_compra_id` está DEPRECATED pero sigue escribiéndose en un caso (`types/database.ts:289-291`). `RegistrarPagoProveedorModal` de Local sigue llamando a v1 (`apps/virikyna-local/src/pages/CierreCaja/RegistrarEgresoModal.tsx:37-40`).
11. `productos.codigo_interno` quedó para los códigos `INT-…` viejos; la limpieza "queda para una migración posterior" (`docs/49_codigo_interno_apps.sql:17`).
12. **Mucho código duplicado entre Local y Gestión**: Clientes (`ClientesPage`, `ClienteFormModal`, `ClienteDetalleModal`, `RegistrarPagoClienteModal`), `ProveedorFormModal`, `FacturaCompraDetalleModal`, `FacturasCompraTab`, `CierreDetalleModal`, `HistorialPrecioTab`, `ComprobanteModal`, `ConfirmDialog`, `FormField`, `Modal`, `icons`; y 3 formularios de producto distintos (`ProductoFormSheet` de Local, `ProductoFormModal` de Gestión, `ProductoFormSheet` de Inventario).
13. Archivos **sin uso**: `apps/virikyna-gestion/src/components/ModulePlaceholder.tsx` (solo su definición) y `apps/virikyna-inventario/src/auth/RequireRole.tsx` (no se importa en `App.tsx`).
14. La ruta `/carga-inicial` de Local está en el router sin condición; solo se oculta del menú si la carga está cerrada (`apps/virikyna-local/src/App.tsx:35`, `layout/AppShell.tsx:45-51`). A VERIFICAR si la página bloquea por sí misma.
15. `productos_todos` permite INSERT/UPDATE directo a cualquier usuario activo. La protección de margen e IVA depende de un trigger y no de RLS. El historial de margen se deriva de `auditoria` (solo admin) y docs/67 agrega otra tabla de historial: dos fuentes.
16. `auditoria` pesa 23 MB por los triggers genéricos con la fila completa (`docs/67_alerta_cambio_precios.sql:13-15`).
17. Offline: `docs/05_stack_tecnico.md` y las skills describen PowerSync/SQLite; **no está implementado**.
18. React Query se usa solo en parte; la mayoría de las pantallas usan `useState`/`useEffect` con recargas manuales.
19. Tests solo de lógica pura de `packages/shared` (9 archivos); ningún test de RPC versionado en CI (los tests SQL viven dentro de cada migración como `BEGIN … ROLLBACK`).
20. "Terminal #001" hardcodeado en el header de Local (`AppShell.tsx:138`) y `ventas.terminal_id` con default `'POS001'`: no hay multi-terminal.
21. La Edge Function ARCA depende de un fork (`@aledj02/afip.js@0.8.2`) con un bug parcheado a mano (`supabase/functions/arca-emitir-factura/index.ts:19-24`).
22. `cuentas_saldo` aparece dos veces en el dump: un placeholder sin `security_invoker` y después la definición real (`schema.sql:3270-3275` y `:4065-4072`), un artefacto de pg_dump; docs/vistas advierte que `CREATE OR REPLACE VIEW` pierde `security_invoker`.

---

### Checklist

- [x] Recorridos los 3 sistemas (rutas, menús y páginas de Local, Gestión e Inventario, más `packages/shared` y las Edge Functions).
- [x] Cada módulo con sus archivos citados.
- [x] Modelo de producto y variantes explicado (4.5).
- [x] Matriz de reutilización completa (5.1 y 5.2).
- [x] Ningún archivo de código modificado por esta auditoría: la única escritura es este `.md`. Los demás cambios del `git status` (Dashboards de Local, `DefectuososCard`, `docs/06`, `docs/58`) **son de otra sesión** que trabaja en paralelo y no se tocaron.
