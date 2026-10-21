# Auditoría del lote de cambios — octubre 2026

Fecha: 2026-10-19. Alcance: Virikyna Gestión, Virikyna Inventario y Virikyna Local.
Modo: **solo lectura**. No se modificó código, schema ni datos. Nada commiteado.

Fuentes:
- Base de producción (`ccpinvtleqlsukcqnili`), consultada con `supabase db query --linked`, solo `SELECT`.
- Dump del esquema del backup de hoy (`schema.sql`, ver Paso 0). Es la foto exacta de las funciones, vistas y constraints de producción.
- Código del repo en `main` (`bce8a99`), con el working tree de hoy.

> Aviso de contexto: el working tree tiene cambios ajenos a esta auditoría. Están modificados `docs/02_roles_y_permisos.md` y `docs/06_estructura_de_datos.md`, y sin trackear `docs/37…39`, de otra sesión. El próximo número libre de `docs/NN` es **44**.

---

## Paso 0 — Backup

| | |
|---|---|
| Carpeta | `C:\Users\Usuario\Desktop\Theaux soluciones\backups\virikyna_2026-10-19_post-inventario\` (fuera del repo, no está dentro de ningún repo git) |
| Método | `pg_dump` / `pg_dumpall` 17.6 portables. `supabase db dump` no corre sin Docker, y Docker no está instalado. Los filtros son los mismos que usa la CLI. |
| Script reutilizable | `C:\Users\Usuario\Desktop\Theaux soluciones\backups\backup-virikyna.ps1` (contraseña en `.secrets\supabase-db-password.txt`, gitignored, ACL solo del usuario) |

| Archivo | Tamaño | Contenido |
|---|---|---|
| `schema.sql` | 218.575 B (0,21 MB) | Esquema `public`, sin los esquemas administrados por Supabase |
| `data.sql` | 7.605.112 B (7,25 MB) | Datos de `public` + `auth` (usuarios) + `storage` |
| `roles.sql` | 6.173 B | Roles, sin contraseñas |
| `conteos.txt` | 1.857 B | Filas por tabla al momento del dump |

Conteos clave: 2.164 productos, 2.164 `stock_ubicaciones`, 2.438 `movimientos_stock`, 20 proveedores, 10 usuarios, 1 factura de compra (1 ítem), 1 pago a proveedor, 3 ventas, 9.771 filas de `auditoria`.

**Pendiente:** el backup todavía no se probó restaurándolo. Plan Free: este script es el único respaldo que hay.

---

## Hallazgos transversales (leer primero)

1. **PowerSync no existe en el proyecto.** Se descartó en `docs/05` ("Decisión revisada"). Las tres apps hablan directo con Supabase: REST, RPC y Edge Functions. No hay SQLite local ni cola offline. Todo lo que el pedido plantea sobre "escrituras locales PowerSync" o "DELETE sincronizado" no aplica. Local sin conexión simplemente falla la escritura.
2. **Ya existe una normalización de texto** (`docs/42`, trigger `normalizar_texto_producto`). Pone `productos.nombre`/`marca` en MAYÚSCULAS y `descripcion` en formato oración, pero **conserva los acentos**. Además cubre solo `productos`, `carga_inicial_items` y los ítems libres de factura.
3. **El IVA del producto ya existe como columna**: `productos.iva_porcentaje numeric DEFAULT 21`. `precio_venta` es una **columna generada** de Postgres que lo usa. "Lleva IVA" se puede resolver con 0 / 21 sobre esa columna, sin fórmula nueva.
4. **2.163 de 2.164 productos tienen `precio_manual` y no tienen costo** (vienen de la carga inicial). Para ellos la fórmula de precio no se aplica, y el flag de IVA del producto no cambia nada hasta que se les cargue un costo.
5. **La única factura de compra es un CUPÓN con 21 % de IVA sumado** ($41.237,28) **y ya figura pagada por el total con IVA** ($237.605,28 en efectivo). Es justo el caso que corrige la sección F.
6. **Causa global probable de modales que "se cierran solos":** el `AuthProvider` de las tres apps desmonta toda la pantalla cada vez que Supabase refresca el token, más o menos una vez por hora. Detalle en B.
7. **`]C1` no es "basura": es el identificador de simbología AIM de Code 128 (GS1-128).** Dejar "solo dígitos" deja un `1` de más: `]C107727030081616` → `107727030081616`, cuando lo correcto es `07727030081616`. Detalle en C.
8. La constante JS `IVA_DEFAULT = 21` (`packages/shared/lib/inventario.ts`) se usa **para dos cosas distintas**: el IVA del producto (vista previa del formulario) y el IVA de la factura de compra (vista previa de totales). E y F tienen que separarlas.

---

## A — Normalización de texto (MAYÚSCULAS / Oración / sin acentos)

### A.1 Columnas de texto y clasificación

Medido sobre producción. "Acento" = contiene á é í ó ú ü (o con grave). "Fuera de formato" = no cumple la regla propuesta: MAYÚSCULA = `upper(btrim(x))`, ORACIÓN = primera letra mayúscula y el resto minúscula.

| Tabla.columna | Clasificación | Motivo | No nulos | Con acento | Fuera de formato | Con ñ |
|---|---|---|---:|---:|---:|---:|
| productos.nombre | MAYÚSCULA | Identificador (ya lo hace el trigger docs/42) | 2.164 | **397** | 0 | 195 |
| productos.marca | MAYÚSCULA | Identificador | 1.617 | 1 (`OCÉANO TRAVESÍA`) | 0 | 5 |
| productos.descripcion | ORACIÓN | Texto libre (ya lo hace docs/42) | 583 | 17 | 0 | 3 |
| carga_inicial_items.nombre / marca | MAYÚSCULA | Borrador de producto, mismo trigger | 0 | 0 | 0 | 0 |
| carga_inicial_items.descripcion | ORACIÓN | idem | 0 | 0 | 0 | 0 |
| venta_items.producto_nombre / producto_marca | MAYÚSCULA | Snapshot del producto (no hay comprobantes fiscales emitidos) | 3 / 3 | 0 | 0 | 0 |
| devolucion_items.producto_nombre / producto_marca | MAYÚSCULA | Snapshot | 0 | 0 | 0 | 0 |
| facturas_compra_items.descripcion | MAYÚSCULA | Copia de `productos.nombre` o ítem libre | 1 | 0 | 0 | 0 |
| proveedores.razon_social | MAYÚSCULA | Identificador | 20 | 0 | 0 | 1 |
| proveedores.contacto | MAYÚSCULA (a decidir) | Nombre de persona; a veces trae teléfono (`+54 9 351… (SEBA)`) | 4 | 0 | 1 (`Juan Pablo`) | 0 |
| proveedores.direccion | MAYÚSCULA (a decidir) | Domicilio | 19 | 0 | 0 | 1 |
| proveedores.observaciones | ORACIÓN (a decidir) | Texto libre **multilínea**; la regla de oración pasaría a minúscula el resto de cada línea | 3 | 1 | 3 | 0 |
| clientes.razon_social | MAYÚSCULA | Identificador | 2 | 0 | 0 | 0 |
| clientes.nombre_fantasia | MAYÚSCULA | Identificador | 0 | — | — | — |
| clientes.domicilio | MAYÚSCULA (a decidir) | Domicilio | 0 | — | — | — |
| cuentas.nombre | MAYÚSCULA (a decidir) | Nombre de cuenta (`Mercado Pago`, `Efectivo`, `Galicia`); **UNIQUE**; el código no la referencia por texto | 3 | 0 | 3 | 0 |
| perfiles.nombre | MAYÚSCULA (a decidir) | Nombre de usuario (`Jimena`, `Belu`…); se ve en tickets e historial | 10 | 0 | 10 | 0 |
| ventas.nota | ORACIÓN | Texto libre | 0 | — | — | — |
| devoluciones.motivo_detalle / observaciones / motivo_anulacion | ORACIÓN | Texto libre | 0 | — | — | — |
| egresos.descripcion | ORACIÓN | Libre; hoy 1 fila generada por RPC (`Pago a proveedor`) | 1 | 0 | 0 | 0 |
| movimientos_cuenta.descripcion | ORACIÓN | Libre + textos generados (`Corrección: …`, `Reversión desde Historial`) | 0 | — | — | — |
| movimientos_stock.motivo | ORACIÓN | Libre + generado (`Carga inicial: corrección de cantidad (6.00 → 5)`, `Devolución de venta #…`) | 2.418 | **208** | 0 | 0 |
| notas_internas.mensaje | ORACIÓN | Texto libre | 0 | — | — | — |
| pagos_proveedor.nota | ORACIÓN | Libre + generado (`Reversión desde Historial`) | 0 | — | — | — |
| arca_wsaa_tokens.* (ambiente, cuit, servicio, sign, token) | EXCLUIR | Configuración/credenciales ARCA | | | | |
| auditoria.nota, auditoria.tabla_afectada, valores_* (jsonb) | EXCLUIR | Histórico append-only; JSON; `tabla_afectada` lo usa el código | | | | |
| carga_inicial_items.accion, carga_inicial_operaciones.operacion | EXCLUIR | Valores de CHECK usados por código | | | | |
| carga_inicial_items.codigo_barras, productos.codigo_barras, productos.codigo_interno | EXCLUIR | Códigos (ver C) | | | | |
| clientes.cuit, clientes.mail, clientes.celular | EXCLUIR | CUIT / email / teléfono | | | | |
| proveedores.cuit, proveedores.mail, proveedores.telefono | EXCLUIR | CUIT / email / teléfono | | | | |
| facturas_c.* (cae, numero_factura, punto_venta, pdf_url, enviado_a) | EXCLUIR | Datos fiscales ARCA / URL / email | | | | |
| facturas_compra.punto_venta, numero_comprobante | EXCLUIR | Identificadores de comprobante | | | | |
| pagos_proveedor.cheque_numero | EXCLUIR | Identificador | | | | |
| ventas.client_id, ventas.terminal_id | EXCLUIR | IDs técnicos (idempotencia) | | | | |
| notas_internas.origen | EXCLUIR | CHECK (`local`/`gestion`) | | | | |
| Todas las columnas enum (`estado`, `tipo`, `forma_pago`, `rol`, `categoria`, `motivo` de devoluciones, etc.) | EXCLUIR | Enums de Postgres | | | | |

No hay tablas de categorías ni de marcas: `marca` es texto libre en `productos`, y `categoria` solo existe como enum en `egresos`.

### A.2 Ejemplos con acento
`MUÑECO MINECRAFT EN BLÍSTER CON ACCESORIOS`, `PIZARRA MÁGICA CARS GRANDE EN CAJA`, `LIBRO TALLER DE TÉMPERAS`, `SÚPER HÉROE AVENGERS`, `LEGÓ BLOCKY DINOS 65 PIEZAS`, `DIARIO ÍNTIMO HELLO SUNNER`. En descripción: `Con lápiz`, `Llaves cubo didáctico…`. En `movimientos_stock.motivo`: `corrección` (texto generado por el RPC de carga inicial) y los motivos fijos de ajuste del código (`'Pérdida'`, `'Corrección de conteo físico'` en `MOTIVOS_AJUSTE_STOCK`).

### A.3 Unique constraints / colisiones al normalizar (upper + sin acento)

- Los UNIQUE sobre texto son estos: `cuentas.nombre` (no hay colisión), `productos.codigo_barras`, `productos.codigo_interno` y `carga_inicial_items (usuario_id, codigo_barras)`. Los tres últimos están excluidos de A. **No hay ninguna violación de UNIQUE posible.**
- Hay duplicados lógicos sin constraint en `productos`: 3 pares pasan a ser idénticos (nombre + marca) al quitar los acentos.
  - `JUEGO DE MESA CODIGO SECRETO` / `JUEGO DE MESA CÓDIGO SECRETO` [DEVIR]
  - `JUEGO DE MESA 4 EN LINEA` / `JUEGO DE MESA 4 EN LÍNEA` [RUIBAL]
  - `LIBRO APRENDO LOS TRAZOS LAS MAYUSCULAS` / `… MAYÚSCULAS` [BETINA]
- Además ya hay **35 grupos de nombre + marca exactamente repetidos**, desde antes y sin relación con los acentos.
- `proveedores.razon_social`: sin colisiones.

### A.4 Extensión `unaccent`
Está disponible pero **no instalada** (`pg_trgm` y `citext` tampoco). **Ojo:** `unaccent` convierte `ñ → n`, y la regla pide conservar la ñ. Hay dos alternativas: un `translate(x, 'áéíóúüàèìòùÁÉÍÓÚÜÀÈÌÒÙ', 'aeiouuaeiouAEIOUUAEIOU')` explícito (no necesita extensión y respeta la ñ), o `unaccent` con un diccionario propio. La collation es ICU `en-US`: `upper()` respeta la Ñ.

### A.5 Cómo escribe cada app (texto)

| Tabla | Gestión | Local | Inventario | Server-side |
|---|---|---|---|---|
| productos | `insert/update` directo (`ProductoFormModal`) | directo (`ProductoFormSheet`) | directo (`ProductoFormSheet`) | `carga_inicial_finalizar`, `carga_inicial_editar_producto`, `revertir_edicion/alta`, `cargar_factura_compra`, `actualizar_precios_masivo` |
| proveedores | directo (`ProveedorFormModal`) | directo (`ProveedorFormModal`, copia casi idéntica) | — | `eliminar_proveedor` |
| clientes | directo (`ClienteFormModal`) | directo (`ClienteFormModal`, copia) | — | — |
| notas_internas | directo (`NuevaNotaModal`) | directo (copia) | — | — |
| perfiles.nombre | Edge `admin-usuarios` (alta) + RPC `editar_usuario` | — | — | — |
| textos libres de movimientos | RPCs: `ajustar_stock`, `registrar_egreso_general`, `registrar_movimiento_caja_general`, `transferir_entre_cuentas`, `editar/eliminar_movimiento_cuenta`, `registrar_pago_proveedor_v2`, `anular_*`, `agregar_nota_correccion` | RPCs: `confirmar_venta` (nota), `crear_devolucion`, `registrar_retiro_caja`, egresos | `ajustar_stock` | — |

La vía robusta es la misma que eligió `docs/42`: un trigger `BEFORE INSERT OR UPDATE` por tabla, que cubre a la vez las escrituras directas, las RPCs y las tres apps. Los textos que **generan** las RPCs (`'Corrección: '`, `'Reversión…'`, `'Anulación de…'`) tienen acentos en el código SQL. El trigger los limpiaría igual, pero conviene corregir también las constantes.

### A.6 Utilidades de normalización existentes
- SQL: `normalizar_texto_producto()` (productos y carga inicial, sin quitar acentos) y `normalizar_descripcion_item_libre()` (ítems libres de factura).
- JS (`packages/shared`): `MAYUSCULAS` (clase CSS `uppercase`: solo visual, el valor viaja tal cual), `productoBusqueda.normalizar()` (trim + lowercase), `normalizarCodigoBarras()` (quita espacios).
- `apps/virikyna-gestion/src/pages/Facturacion/filtroVentas.ts:13`: es el **único** lugar que quita diacríticos (`normalize('NFD')`), y solo para el filtro de ventas de Gestión.

### A.7 Búsquedas
- Hoy **distinguen acentos pero no mayúsculas**: usan `ilike` (`armarFiltroBusquedaProducto`) y `toLowerCase().includes()` (`coincideBusquedaProducto`, listas de proveedores y clientes). Ejemplo: buscar `linea` no encuentra `4 EN LÍNEA`.
- Después de normalizar la base, el problema se invierte: quien tipee `línea` no va a encontrar `LINEA`. **Hay que quitar los acentos también de lo que se tipea**, en `normalizar()` y `armarFiltroBusquedaProducto()` en shared, y en las listas de proveedores y clientes de Local y Gestión. Con eso la búsqueda pasa a ignorar acentos en todas las apps. Los códigos no se ven afectados.

---

## B — Modales, drawers y formularios

### B.1 Librería y control de cierre
- **No se usa ninguna librería.** Hay dos componentes propios en shared: `Modal` (escritorio: Local y Gestión) y `BottomSheet` (pantalla completa: Inventario, más algunos de Local). Los dos se renderizan con un portal a `body`.
- **Click afuera:** no cierra nunca, por diseño (`Modal.tsx:42`). `BottomSheet` ocupa toda la pantalla.
- **Esc:** solo si se pasa la prop `dialogo={{ onEscape }}` (`useFocoAtrapado`). Sin ella, Esc no hace nada.
- **Swipe:** no hay gestos. Pero en Android el **botón o gesto "Atrás"** hace `history.back()` (las apps usan HashRouter) y desmonta la pantalla junto con su modal, porque el estado del modal no está en la URL. Solo `CargarFacturaPage` (Inventario) lo bloquea con `useBlocker`.
- **No hay `onOpenChange`.** El cierre es `onClose`. El patrón de formulario es `pedirCierre()`: si `dirty` es true, muestra un `ConfirmDialog` "Cerrar sin guardar". Si no, cierra directo.
- El `dirty` se marca con `onChangeCapture` del `<form>`. Los cambios **programáticos** (código leído por la cámara, producto elegido de un buscador, ítems agregados) no disparan `change` y pueden dejar `dirty=false`. En ese caso ✕ cierra sin preguntar. Hay que verificarlo caso por caso.

### B.2 Inventario de modales, drawers y formularios

`pedirCierre`: pide confirmación si hay cambios. `Esc`: tiene prop `dialogo`.

| App | Componente | Tipo | Cierre con cambios | Esc |
|---|---|---|---|---|
| shared (Local+Gestión) | CargarFacturaCompraModal | Modal, formulario largo | confirma | **no** |
| shared | EditarFacturaCompraModal, AnularFacturaCompraModal, PagarProveedorModal, ActualizarPreciosModal | Modal, formulario | confirma | sí (con confirmación) |
| shared | ConfirmDialog, ComprobanteModal, SelectorFacturaCopiaModal | Modal, sin datos | directo | sí |
| shared | Editor de carga inicial (`cargaInicial/comunes.tsx`) | Sheet/Modal | directo (`onClose`) | sí |
| Gestión | ProductoFormModal, ProveedorFormModal, ClienteFormModal, UsuarioFormModal, BlanquearPasswordModal, AjustarStockModal, EditarMovimientoModal, NotaCorreccionModal, NuevaNotaModal, RegistrarPagoClienteModal | Modal, formulario | confirma | no |
| Gestión | RegistrarPagoProveedorModal | Modal, formulario | confirma | sí |
| Gestión | CierreDetalleModal, ClienteDetalleModal, DetalleAuditoriaModal, PendienteCobroModal, PendientePagoModal, ChequesEmitidosModal | Modal, detalle | directo | no |
| Gestión | FacturaCompraDetalleModal, FacturaCompraDetallePorId, ProveedorFacturasPendientesModal | Modal, detalle | directo | sí |
| Local | ProductoFormSheet, ProveedorFormModal, ClienteFormModal, AjustarStockSheet, RegistrarEgresoModal, RegistrarPagoClienteModal, RegistrarPagoProveedorModal, RegistrarRetiroModal, ConfirmarCierreZModal, NuevaNotaModal | Modal, formulario | confirma | no |
| Local | AjustePorcentajeModal, DevolucionModal | Modal, formulario | confirma | sí |
| Local | Confirmar venta (VentasPage), PagoCombinadoModal | Modal | directo | sí |
| Local | CierreDetalleModal, ClienteDetalleModal, DevolucionDetalleModal, FacturaCompraDetalleModal/PorId, modal de DevolucionesTab | Modal, detalle | directo | parcial |
| Inventario | ProductoFormSheet, AjustarStockSheet | BottomSheet, formulario | confirma | no |
| Inventario | ActualizarPreciosSheet | BottomSheet, formulario | confirma | sí |
| Inventario | SelectorFacturaCopiaSheet; modal de InventarioPage | detalle | directo | parcial |
| Inventario | **CargarFacturaPage** (página, no modal) | formulario largo | `useBlocker` + `beforeunload` | — |
| Local | **VentasPage** (tickets) | página | tickets persistidos en localStorage | — |

Hoy ningún formulario se cierra por click afuera ni por timers propios. Los cierres "solos" vienen de causas globales que desmontan la pantalla entera.

### B.3 Causas globales de pérdida de estado

| # | Causa | Dónde | Severidad |
|---|---|---|---|
| 1 | **Refresh de sesión desmonta la app.** Ante *cualquier* evento de `onAuthStateChange` con sesión (como mínimo `TOKEN_REFRESHED`, más o menos cada hora con el JWT de 1 h), el provider hace `setLoading(true)` y vuelve a pedir el perfil. Mientras tanto `RequireAuth` renderiza "Cargando…" **en lugar del `<Outlet/>`**: todos los formularios y modales abiertos se desmontan y su estado se pierde. Encaja exacto con "se cierran solos con el tiempo". Según la versión de auth-js también puede saltar al volver a la pestaña; hay que confirmarlo con un log. | `packages/shared/auth/createAuthController.tsx:76-86` (Local, Inventario) y `apps/virikyna-gestion/src/auth/AuthContext.tsx:76-86` + `RequireAuth.tsx:9` (Gestión) | **Alta** |
| 2 | **Auto-update de Local con reinicio sin preguntar.** Al arrancar, `checkForUpdates()` baja la versión nueva y hace `relaunch()`. Si la descarga tarda, el reinicio llega con alguien ya cargando un formulario. | `apps/virikyna-local/src/main.tsx:15`, `lib/updater.ts:35-40` | Media |
| 3 | **El sistema operativo mata la PWA en segundo plano** (Inventario, celular). Al volver, la página se recarga entera. Solo sobreviven los tickets de Ventas y las filas pendientes de la carga inicial (localStorage). La factura de compra del celular se pierde. | Inventario | Alta en celular |
| 4 | **Botón "Atrás" de Android** (o Alt+← en el navegador). Cambia de ruta y desmonta el modal. Solo `CargarFacturaPage` usa `useBlocker`. En Local (Tauri) Alt+← está bloqueado en producción. | Inventario, Gestión | Media |
| 5 | Service worker (Gestión e Inventario): `registerType: 'autoUpdate'` sin el import de `virtual:pwa-register`, así que **no recarga sola**. Riesgo menor: después de activarse un SW nuevo, un chunk lazy viejo (ej. `BarcodeScanner`) puede fallar al cargar. | `vite.config.ts` | Baja |
| 6 | Refetch de queries: `refetchOnWindowFocus: false` en las tres apps, y los formularios inicializan su estado con `useState(props)`. Un refetch no pisa lo tipeado. **No es causa.** | — | — |
| 7 | Timers de inactividad / logout automático: **no existen.** | — | — |
| 8 | Recarga de ventana en Tauri: F5, Ctrl+R y Alt+←/→ bloqueados en producción (`proteccionVentana.ts`). El cierre de ventana solo se bloquea durante un cobro. Un crash del webview no tiene protección. | Local | Baja |

### B.4 Persistencia de borradores existente
- Local, Ventas: tickets en `localStorage` (`Ventas/ticketsStorage.ts`).
- Carga inicial: filas pendientes en `localStorage` (`shared/lib/cargaInicial.ts:311+`) y borradores en el servidor (`carga_inicial_items`).
- **Nada más.** No hay borrador de factura de compra, de producto, de pago ni de devolución.

### B.5 Formularios largos o críticos que necesitan borrador persistente
1. **Factura de compra**: `CargarFacturaCompraModal` (Local y Gestión) y `CargarFacturaPage` (Inventario). Son decenas de ítems; prioridad máxima.
2. Pago a proveedor (`PagarProveedorModal`, con selección de comprobantes y NC).
3. Devolución / cambio (`DevolucionModal`, Local).
4. Formulario de producto (3 apps): son menos campos, pero se carga mientras se escanea.
5. Actualizar precios (selección de productos).

---

## C — Códigos de barra

### C.1 Escaneo por cámara
- **Un solo componente**: `packages/shared/src/components/BarcodeScanner.tsx`. El de Inventario es un re-export.
- Usa `BarcodeDetector` nativo (Chrome/Android, ML Kit). Si no está (iOS), cae al polyfill ZXing `barcode-detector-api-polyfill`.
- Formatos habilitados: `ean_13, ean_8, upc_a, upc_e, code_128, code_39, itf, qr_code`.
- Parseo: `normalizarCodigoBarras(rawValue)` (solo quita espacios) más una validación:
  - EAN-8, EAN-13 y UPC-A exigen dígito verificador válido.
  - Hacen falta 2 lecturas iguales seguidas (3 para ITF y Code 39).
  - **Code 128 y QR no tienen ninguna validación de contenido.**
- La entrada manual dentro del escáner acepta cualquier texto (`trim`).
- Llegada al formulario: `ScanButton` → `onDetect` → `onChange` del campo (`CodigoBarrasBox`, `ProductoBuscador`, ítem de factura, carga inicial).

### C.2 Prefijos de simbología
**Sí, llegan.** En la base hay 19 códigos con `]C1` (AIM de Code 128 con FNC1, es decir GS1-128), todos dados de alta el 13 y 14 de octubre. El `1` es **parte del prefijo**. La forma correcta de limpiarlos es quitar `^\][A-Za-z][0-9A-Za-z]` (3 caracteres) y **después** validar los dígitos. No se vieron `]E0` ni otros prefijos.

### C.3 Columnas que guardan códigos
- `productos.codigo_barras` (UNIQUE; 2.164 filas con valor).
- `productos.codigo_interno` (UNIQUE; **0 filas con valor hoy**).
- `carga_inicial_items.codigo_barras` (UNIQUE por usuario; 0 filas).
- En código: `facturas_compra_items` **no** guarda código (solo `producto_id` y `descripcion`). `codigoBarras` del ítem es solo UI.

### C.4 Datos actuales

21 códigos con caracteres no numéricos:

| Patrón | Cant. | Ejemplos | Limpieza correcta |
|---|---:|---|---|
| `]C1` + 14 dígitos | 18 | `]C107727030081532` (JUEGO DE MESA OEA), `]C107727030081616` (SABELOTODO), `]C107727030081782` (JACKPOT) | `07727030081532` (14 dígitos; **no** pasan como EAN-13: 17 de 18 tienen el dígito verificador inválido, son etiquetas Code 128 del distribuidor) |
| `]C1` + 13 dígitos | 1 | `]C16920220026209` (MÁSCARA AVENGERS) | `6920220026209` |
| `ZZ` + 12 dígitos | 1 | `ZZ619470684278` (PELUCHE ALMOHADA PANDA 10") | `619470684278` (¿UPC-A?, a confirmar) |
| letras + dígitos | 1 | `LS20024` (ARCILLA SUPER SUAVE) | ¿código de proveedor legítimo? → `20024` |

**Colisiones al limpiar** (bien hecho, quitando el prefijo de 3 caracteres). Hay 2, y son productos **duplicados**: el mismo producto se cargó una vez por cámara y otra a mano o con lector.

| Con prefijo | Limpio (ya existe) | Nombre | Stock c/u | Ventas |
|---|---|---|---:|---:|
| `]C107727030081616` (c2ba528d…, 14/10) | `07727030081616` (6d43ba82…, 14/10) | JUEGO DE MESA SABELOTODO | 2 / 2 | 0 / 0 |
| `]C107727030081782` (c025a16e…, 14/10) | `07727030081782` (d4732b29…, 13/10) | JUEGO DE MESA JACKPOT | 2 / 2 | 0 / 0 |

Con la limpieza ingenua ("solo dígitos") no habría colisiones, pero quedarían 18 códigos **incorrectos** de 15 dígitos y estos duplicados seguirían sin detectarse.

Distribución de largos (después de la limpieza correcta):

| Largo | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 10 | 11 | 12 | 13 | 14 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Productos | 1 | 7 | 39 | 74 | 17 | 1 | 8 | 4 | 2 | 170 | 1.802 | 39 |

- 8 = EAN-8; 12 = UPC-A; 13 = EAN-13. Hay **140 códigos cortos (2 a 7 dígitos)**, numéricos: son códigos propios o de proveedor.
- 9 EAN-13 tienen el dígito verificador inválido (ej. `7794675829182` PICTIONARY, `2025080102646` DIARIO INTIMO). Son tipeos o códigos propietarios.
- No hay pares 12/13 duplicados (con y sin el 0 adelante).

### C.5 Códigos internos
Existen **dos generadores distintos**:
1. SQL `generar_codigo_interno()`: `'20'` + secuencia de 10 dígitos + dígito verificador EAN-13, es decir **numérico, 13 dígitos**. Lo usa `carga_inicial_finalizar` cuando el borrador no tiene código, y lo guarda en **`codigo_barras`**. Hay **28 productos** con código `20…` de 13 dígitos.
2. JS `generarCodigoInterno()` (`packages/shared/lib/format.ts:35`): `INT-` + base36, es decir **alfanumérico**. Lo usan los 3 formularios de producto al dar de alta sin código, y lo guarda en `codigo_interno`. Hoy no hay ninguno, pero el próximo alta sin código va a generar uno con letras.

Si la regla "solo dígitos" se aplica también a los códigos internos, el generador JS choca con ella. La opción natural es pasar los formularios al RPC `generar_codigo_interno`.

### C.6 Lector físico (HID)
**No comparte la lógica de la cámara.** Se reporta antes de tocar nada:
- Ventas (Local), `Ventas/ProductoBusqueda.tsx`: `buscarPorCodigoExacto` propio. Prueba el texto tal cual, en mayúsculas y en minúsculas. **No** usa `variantesCodigoBarras` (12/13), no quita prefijos AIM ni normaliza.
- Formularios de producto, factura y carga inicial: el lector escribe en el mismo input que la cámara (`CodigoBarrasBox`, ítem de factura). La resolución de código sí es compartida (`resolverCodigoBarras` / `codigoBarrasCoincide`, con variantes 12/13), pero sin filtrar caracteres.
- Servidor: `carga_inicial_guardar_item` y `codigo_barras_variantes` solo quitan espacios. `productos.codigo_barras` no tiene CHECK de formato.

Para que "la cámara solo acepta dígitos" no rompa el HID, el filtro tiene que ir en `BarcodeScanner` (quitar el AIM y exigir dígitos solo en lecturas de cámara). Si además se quiere una regla de datos (CHECK o trigger), aplica a todas las vías y choca con `LS20024` y con `INT-…`.

---

## D — Eliminar producto

### D.1 Roles y permisos
- `perfiles.rol` (enum `admin`/`cajero`) + `perfiles.activo`.
- **Gestión**: solo admin. El `AuthContext` hace `signOut` si el rol no es admin.
- **Local e Inventario**: los dos roles. La UI se limita con `esAdmin` (`ProductoFormSheet`: márgenes, historial y ajuste de stock).
- RPCs: chequean `rol = 'admin'` adentro (`ajustar_stock`, `anular_*`, `revertir_*`, `eliminar_proveedor`…).
- **RLS de `productos`**: una sola policy, `productos_todos`, para **todas las operaciones (`*`)** y cualquier perfil activo. `authenticated` tiene el GRANT de `DELETE`. Hoy **un cajero puede borrar o editar cualquier producto llamando a la API directamente**. Lo único protegido por trigger son los márgenes. El borrado hoy lo frena en la práctica una FK (ver D.2).
- Proveedores ya sigue el patrón deseado: policy `DELETE` solo admin + RPC `eliminar_proveedor` + trigger `fn_proteger_eliminacion_proveedor`. Clientes usa trigger de protección y ofrece "inactivar" en la UI.

### D.2 FK que referencian `productos`

| Tabla.columna | ON DELETE |
|---|---|
| stock_ubicaciones.producto_id | **CASCADE** |
| carga_inicial_items.producto_id | SET NULL |
| movimientos_stock.producto_id | NO ACTION (bloquea) |
| venta_items.producto_id | NO ACTION |
| devolucion_items.producto_id | NO ACTION |
| facturas_compra_items.producto_id | NO ACTION |
| auditoria.registro_id | sin FK: queda la fila `eliminacion` con `valores_anteriores` (trigger `fn_auditoria_generica`) |

No existen tablas de variantes ni de códigos aparte.

### D.3 Campo activo / inactivo
`productos.estado` (enum `activo`/`inactivo`). Hoy **los 2.164 están activos**. Dónde se usa:
- Ventas: el buscador filtra `estado = 'activo'`.
- `crear_devolucion`: los ítems nuevos tienen que estar activos.
- `productos_stock_bajo`.
- `resolverCodigoBarras`: distingue los inactivos.
- Factura de compra: aviso "producto inactivo" (`docs/33`).
- `revertir_alta`: inactiva en lugar de borrar.
- Selector "Estado" en los 3 formularios.

### D.4 PowerSync y offline
No aplica (no hay PowerSync). Un DELETE es una llamada REST o RPC directa. Sin conexión falla con error de red; no hay cola ni conflicto.

### D.5 Productos "sin nada asociado" hoy

| Criterio | Cantidad |
|---|---:|
| Sin ventas, devoluciones, compras **ni movimientos de stock** | **0** (los 2.164 tienen su movimiento `inicial` de la carga) |
| Sin ventas, devoluciones ni compras (pueden tener el movimiento de carga inicial) | 2.161 |
| idem + stock total 0 | 14 |

Productos con operaciones reales: 2 con venta, 1 con compra, 2 con ajuste. Hay que decidir si el movimiento `inicial` cuenta como "asociado" (ver Decisiones).

### D.6 Propuesta
- RPC `eliminar_producto(p_producto_id)`, `SECURITY DEFINER`, que:
  - chequee admin activo;
  - si existen `venta_items`, `devolucion_items`, `facturas_compra_items` o movimientos que no sean `inicial`, levante un error claro, o inactive (según la decisión);
  - si no, borre los movimientos `inicial`, `stock_ubicaciones` (cascade) y el producto, en una transacción.
- Partir `productos_todos` en policies por operación: `SELECT`/`INSERT`/`UPDATE` para activos, `DELETE` para nadie (solo vía RPC). Hacer `REVOKE DELETE` a `authenticated`.
- UI: botón "Eliminar" solo para admin, con `ConfirmDialog`. Si la RPC responde "tiene historial", ofrecer "Inactivar", igual que hoy en Clientes.
- Trade-offs:
  - Borrar los movimientos de carga inicial pierde trazabilidad en `movimientos_stock`. Queda en `auditoria` (alta del movimiento + eliminación del producto con sus valores).
  - La alternativa es *soft delete* siempre (inactivar + ocultar). Es más simple y no pierde nada, pero el catálogo acumula basura.
  - Validar en el servidor evita la carrera "se vendió mientras confirmaba".
- Los 2 duplicados de C son los primeros candidatos.

---

## E — Precio de venta e IVA del producto

### E.1 Dónde se calcula el precio de venta
| Lugar | Qué hace | ¿Duplicado? |
|---|---|---|
| **Columna generada** `productos.precio_venta` = `COALESCE(precio_manual, redondear_precio_venta(costo × (1+m1/100) × (1+m2/100) × (1+iva_porcentaje/100)))` y `precio_calculado` (sin redondeo) | **Fuente de verdad**: Postgres la recalcula sola ante cualquier cambio de costo, márgenes, IVA o precio manual | — |
| SQL `redondear_precio_venta()` (docs/30) | Redondeo escalonado (<500 a la centena; <10.000 a múltiplo de 500 con corte 200; ≥10.000 al mil) | Espejo en JS |
| JS `packages/shared/lib/precios.ts`: `calcularPrecio`, `redondearPrecioVenta`, `costoConPorcentaje`, `precioManualConPorcentaje`, `cambiosPrecioFactura` | **Solo vistas previas**: formularios de producto (3 apps), Actualizar precios, aviso de cambio de precio en la factura | Espejo intencional, con tests (`tests/precios.test.ts`) y script de paridad (`scripts/paridad-precios.ts`) |
| RPCs (`cargar_factura_compra`, `actualizar_precios_masivo`, `carga_inicial_*`, `revertir_edicion`) | No calculan el precio: escriben costo, márgenes y `precio_manual`, y la columna generada hace el resto | — |
| Edge Functions | No intervienen (ARCA emite Factura C sin IVA discriminado) | — |

**No hay triggers que calculen el precio**, ni copias de la fórmula en las apps fuera de `precios.ts`. La fórmula ya está centralizada.

### E.2 Dónde vive el 1,21
- Base: `productos.iva_porcentaje numeric(5,2) DEFAULT 21 NOT NULL`. Hoy los 2.164 tienen 21.
- JS: `IVA_DEFAULT = 21` en `packages/shared/lib/inventario.ts:7`. Se usa en las vistas previas de los 3 formularios (producto nuevo) **y** en el total de la factura de compra (`facturasCompra.ts:124`).
- Ningún formulario edita `iva_porcentaje`: muestran el texto "Costo × margen 1 × margen 2 × IVA {n}%".

### E.3 "Actualizar precios por %"
RPC `actualizar_precios_masivo(p_porcentaje, p_proveedor_id | p_producto_ids)`:
- Producto **con** `precio_manual`: el % se aplica **sobre el precio manual**, con redondeo escalonado.
- Producto **sin** `precio_manual`: el % se aplica **sobre el costo**, y el precio sale de la columna generada, que ya incluye `iva_porcentaje`.
- **Respeta el flag automáticamente** si el flag es `iva_porcentaje`. La vista previa (`useActualizarPrecios.ts:147`) usa `p.iva_porcentaje`, así que también lo respeta.
- UI: `ActualizarPreciosModal` (shared, Local y Gestión) y `ActualizarPreciosSheet` (Inventario).

### E.4 Compras que actualizan costo
`cargar_factura_compra` (salvo NC/ND y precio 0):
- Pone `costo = precio_unitario_sin_iva` de la **última** línea de cada producto.
- Si el proveedor es otro, hereda sus márgenes default.
- **Borra `precio_manual`**.
- El precio de venta se recalcula solo (columna generada). La vista previa es `cambiosPrecioFactura` (JS).
- Hallazgo lateral: el costo toma el precio unitario **sin aplicar el `descuento_porcentaje` de la línea**.

### E.5 Pantallas aptas para acción masiva
- Local y Gestión: `ProductosTab` (shared). **Ya tiene selección con checkboxes** y el botón "Actualizar precios".
- Inventario: `InventarioPage` (lista de celular). La selección vive en `ActualizarPreciosSheet`.

### E.6 Propuesta
- **No crear una columna `lleva_iva` nueva:** usar `iva_porcentaje ∈ {0, 21}` (CHECK) y mostrarlo en la UI como un switch "Lleva IVA".
  - Así la fórmula queda en un solo lugar (la columna generada) y "Actualizar precios" no se toca.
  - Si se prefiere un booleano explícito, puede ser `lleva_iva boolean`, con `iva_porcentaje` generado a partir de él. Pero cambiar la expresión de una columna generada exige `ALTER … SET EXPRESSION` (PG17), que reescribe la tabla.
- Formularios (3 apps): un switch que recalcula con `calcularPrecio` y muestra el precio nuevo antes de guardar. Hoy la vista previa ya existe.
- Acción masiva: RPC admin-only `marcar_iva_productos(p_ids uuid[], p_lleva_iva boolean)` (UPDATE sobre `iva_porcentaje`, auditado por el trigger genérico), con vista previa del precio nuevo, desde `ProductosTab` y la lista de Inventario.
- Separar las constantes JS: `IVA_PRODUCTO_DEFAULT` y alícuotas de compra (F).
- **Decisión clave**: qué pasa al cambiar el flag en un producto con `precio_manual` (son 2.163). Ver Decisiones.

---

## F — IVA en facturas de compra

### F.1 Tablas
- `facturas_compra`: `total_sin_iva`, `iva`, `total` (numeric 12,2). **No guarda la alícuota.**
- `facturas_compra_items`: `precio_unitario_sin_iva`, `descuento_porcentaje`, `precio_total_sin_iva`. No tiene IVA por ítem.

### F.2 Dónde se calcula el IVA
| Lugar | Detalle |
|---|---|
| RPC `cargar_factura_compra` | `v_iva := ROUND(v_total_sin_iva * 0.21, 2)` **hardcodeado, para todos los tipos** |
| JS `calcularTotalesFacturaCompra` (`shared/lib/facturasCompra.ts:113`) | Vista previa con `IVA_DEFAULT` |
| UI | Texto fijo "IVA (21%)": `CargarFacturaCompraModal.tsx:280` (Local y Gestión) y `CargarFacturaPage.tsx:463` (Inventario) |
| RPC `editar_factura_compra` | Cambia el tipo, letra, número, fechas y forma de pago, **pero no recalcula IVA ni total** |
| Vistas | `facturas_compra_saldo` y `proveedores_saldo` usan `fc.total` (NC en negativo). No recalculan IVA. |
| Triggers | Ninguno sobre importes de compra |

### F.3 Impacto en saldo, pagos y notas
- Deuda con el proveedor: `proveedores_saldo.saldo_actual = saldo_inicial + Σ total (NC en negativo) − Σ pagos`.
- Saldo por comprobante: `facturas_compra_saldo.saldo_pendiente = total − aplicaciones vigentes`.
- `registrar_pago_proveedor_v2` imputa contra ese saldo. Las NC aportan crédito igual a su `total`.

**Si se guarda bien el `total` (con o sin IVA según la alícuota), saldos, pagos y NC quedan correctos sin tocar las vistas.** Lo que hay que cambiar es el RPC de carga (recibir la alícuota), el de edición (recalcular al cambiar tipo o alícuota, con cuidado si ya hay pagos aplicados) y las vistas previas y etiquetas.

### F.4 Pantallas
- Carga: `CargarFacturaCompraModal` (shared, Local y Gestión) y `CargarFacturaPage` (Inventario).
- Copia: `useCopiaFacturaCompra` / `SelectorFacturaCopia*`. Hay que decidir si copia la alícuota.
- Edición: `EditarFacturaCompraModal` (shared).
- Detalle: `FacturaCompraDetalleModal` (copias casi idénticas en Local y Gestión) y `ProveedorCuentaCorriente` (shared).

### F.5 Reportes que usen el IVA de compras
Ninguno. El Dashboard, "Pendiente de pago" (`PendientePagoModal`) y la cuenta corriente usan `total` / `saldo_*`. La columna `iva` solo se guarda y se muestra.

### F.6 Propuesta
- `facturas_compra.iva_alicuota numeric(5,2) NOT NULL CHECK (iva_alicuota IN (0, 21))`. Backfill: 21 para la fila existente (hoy tiene IVA).
- `cargar_factura_compra(…, p_iva_alicuota)`: `iva = ROUND(total_sin_iva × alícuota/100, 2)`. Defaults por tipo **en la UI**, con una función compartida `alicuotaDefault(tipo)`:
  - 21 para factura, nota de débito y nota de crédito;
  - 0 para cupón, remito y presupuesto.
- Al cambiar el tipo, se resetea la alícuota al default del tipo nuevo.
- El costo del producto no se toca: ya se toma del precio unitario **sin IVA**.

---

## G — Factura de compra a eliminar (no se borró nada)

### G.1 Identificación
| | |
|---|---|
| ID | `ccc2d35f-eeb4-4cae-a24c-0d8537487056` |
| Proveedor | CARLEVARIS ALEJANDRO (`efb7c750-2c10-4957-979d-cd5bdec49f8b`), márgenes default 100/20 |
| Tipo | **Cupón**, sin letra ni punto de venta, número `1` |
| Fecha | 2026-10-17 (cargada 13:06 UTC) |
| Forma de pago | cuenta corriente |
| Importes | sin IVA $196.368,00 + **IVA $41.237,28** = **total $237.605,28** |
| Ítems | 1: SQUISHI BUTTER MANTECA × 24 a $8.182,00 (local) |
| Estado | `pagada` (saldo pendiente 0) |

### G.2 Efectos registrados
1. **Stock**: movimiento `compra` +24 (`d654e023…`). Stock local 1 → **25** (el 1 vino de la carga inicial).
2. **Producto** `cccaaed9-a863-4590-b2d2-96f3e9e95abe`:

   | | Antes | Después |
   |---|---|---|
   | costo | null | 8.182 |
   | margen 1 / margen 2 | 0 / 0 | 100 / 20 |
   | proveedor | null | CARLEVARIS |
   | precio_manual | 22.000 | null |
   | precio_venta | $22.000 | **$24.000** (calculado 23.760,53) |

   No hubo ventas del producto después de la compra.
3. **Deuda con el proveedor**: +$237.605,28 y después −$237.605,28. Saldo actual del proveedor: $0.
4. **Pago** `172df418-9c9f-4773-911e-ded7a4d853fd` (2026-10-17 17:16, **efectivo**, origen `general`/Gestión) por $237.605,28, con:
   - aplicación `354c762a…` a la factura;
   - egreso `1cfe34ba…` (categoría pago_proveedor);
   - movimiento de cuenta `41154dd3…` por −$237.605,28 en la cuenta `cc43498c…` (la que mapea a efectivo).
5. **Auditoría** (append-only): alta de factura `8c1ac7d5…`, edición del producto `996a6ce1-3166-461c-95d9-3c12413551c5` (con los valores anteriores completos), alta de pago `59f52a74-d861-4d4e-8164-5f7d8fbd4c2f`, aplicación, egreso y movimiento de cuenta.

### G.3 ¿Quedan los costos previos?
**Sí.** En `auditoria` (fila `996a6ce1…`, `valores_anteriores`) y en la pestaña "Historial de precio" del formulario. `revertir_edicion` los puede restaurar tal cual, porque el producto no se volvió a editar después (su `updated_at` coincide con la factura).

### G.4 Flujos existentes de anulación y reversión
| Flujo | Revierte | No revierte |
|---|---|---|
| `anular_factura_compra` (admin, con motivo) | Stock (movimiento `ajuste` −cantidad), marca `anulada`, deja auditoría. La factura sale de la deuda y del saldo. | **No** revierte costo, márgenes, proveedor ni `precio_manual` del producto. **Se niega** si hay pagos o NC aplicados. No borra filas. |
| `revertir_movimiento` sobre el alta del pago | Contrapago negativo, contra-egreso, movimiento de cuenta + (efectivo vuelve a la cuenta), marca la aplicación como revertida | No borra filas |
| `revertir_edicion` sobre la edición del producto | Restaura costo null, márgenes 0/0, proveedor null y `precio_manual` 22.000 | — |

**No existe un flujo de *eliminación* de compra**, solo de anulación.

### G.5 Propuesta de borrado seguro (con reversión completa)
Hacerlo **después de implementar F**, para recargar el cupón ya exento. Se proponen dos variantes:

**Variante 1 — por la app, trazable** (recomendada si importa la historia). Como admin, en este orden:
1. Historial → revertir el pago (auditoría `59f52a74…`). La plata vuelve a efectivo y la factura queda impaga.
2. Anular la factura con motivo "Carga de prueba, se recarga con IVA correcto". El stock vuelve a 1.
3. Historial → revertir la edición del producto (`996a6ce1…`). Vuelve a precio manual $22.000.

Quedan las filas (factura anulada, pago y contrapago, egreso y contra-egreso, 2 movimientos de cuenta, 2 de stock) como rastro.

**Variante 2 — SQL en una transacción, sin rastro operativo** (si se quiere "como si no hubiera existido"):
- `DELETE` en este orden: `pagos_proveedor_aplicaciones` → `movimientos_cuenta` (ref. al pago) → `egresos` → `pagos_proveedor` → `movimientos_stock` (compra) → `facturas_compra_items` → `facturas_compra`;
- `UPDATE stock_ubicaciones −24`;
- `UPDATE productos` a los valores anteriores (con `virikyna.margen_auto_herencia` o como admin, porque cambian márgenes).
- Hay que probarlo antes con `BEGIN … ROLLBACK` y dejarlo como `docs/44`.
- `auditoria` conserva las altas, por ser append-only. Además, los DELETE generan sus filas de `eliminacion`, salvo `virikyna.suppress_audit`.

Antes de cualquiera de las dos: hacer un backup nuevo (`backup-virikyna.ps1 -Etiqueta pre-borrado-factura`).

---

## Decisiones que necesito que tomes

1. **(A) Columnas dudosas.** ¿`proveedores.contacto`, `proveedores.direccion`, `clientes.domicilio`, `cuentas.nombre` y `perfiles.nombre` van en MAYÚSCULAS? ¿`proveedores.observaciones` (multilínea) va en formato oración, o se la deja como está?
2. **(A) Textos generados por el sistema** (`movimientos_stock.motivo`, `movimientos_cuenta.descripcion`, etc.): ¿se normalizan los existentes (son 208 con acento) o solo los nuevos?
3. **(A) Duplicados de nombre.** Los 3 pares que quedan iguales sin acento y los 35 grupos ya duplicados: ¿se dejan, se revisan a mano o se fusionan?
4. **(A) Implementación de "sin acentos".** ¿`translate()` explícito, sin extensión (recomendado, respeta la ñ), o `unaccent` con diccionario propio?
5. **(B) Fix del refresh de sesión.** ¿Aprobás cambiarlo para que solo `SIGNED_IN` / `SIGNED_OUT` / `USER_UPDATED` (o un cambio de usuario) recarguen el perfil, y que el refresh de token no muestre "Cargando…" ni desmonte nada?
6. **(B) Auto-update de Local.** ¿Preguntar antes de reiniciar ("Hay una versión nueva — Reiniciar ahora / Después") en lugar de reiniciar solo?
7. **(B) Borradores persistentes.** ¿En qué formularios, más allá de la factura de compra? ¿Guardarlos en el navegador (`localStorage`, por dispositivo) o en el servidor (visibles desde otro dispositivo)?
8. **(B) Botón "Salir" con confirmación.** ¿Aplica también a los modales de solo lectura (detalles), o solo a los formularios? ¿Esc debe quedar deshabilitado en todos?
9. **(C) Duplicados SABELOTODO y JACKPOT.** ¿Son el mismo producto cargado dos veces (fusionar sumando el stock, 2 + 2 = 4, o quedarse con uno) o hay de verdad 4 unidades de cada uno?
10. **(C) `LS20024` y `ZZ619470684278`.** ¿Las letras son legítimas o se limpian?
11. **(C) Alcance de "solo dígitos".** ¿Solo para la cámara (recomendado), o también como regla de datos (CHECK) para todo código de barras? Si es regla de datos: ¿qué pasa con los códigos internos `INT-…` del generador JS? Propuesta: usar en los formularios el generador SQL numérico `20…`.
12. **(D) "Algo asociado".** ¿El movimiento de stock de la carga inicial cuenta como asociación? Si cuenta, hoy **ningún** producto se podría eliminar y todos se inactivarían.
13. **(D) Inactivar automáticamente.** Si tiene historial, ¿la RPC inactiva sola o devuelve un error y la UI ofrece "Inactivar"?
14. **(E) Modelo del flag.** ¿Reusar `iva_porcentaje` (0/21) o una columna booleana `lleva_iva` aparte?
15. **(E) Productos con precio manual (2.163).** Al desmarcar o marcar el IVA: ¿no pasa nada (el flag solo aplica cuando haya costo), se divide o multiplica el precio manual por 1,21, o se pregunta?
16. **(E) Hallazgo lateral.** El costo que pone la factura ignora el descuento % de la línea. ¿Es intencional o hay que corregirlo?
17. **(F) Edición de comprobantes ya cargados.** ¿Se puede cambiar la alícuota (y el tipo) de un comprobante ya cargado? ¿Y si ya tiene pagos o NC aplicados: se bloquea como hoy el cambio de/a NC?
18. **(F) Copiar factura.** ¿Copia la alícuota del original o usa el default del tipo?
19. **(G) Variante de borrado.** ¿1 (reversiones por la app, queda rastro) o 2 (DELETE en SQL)?
20. **(G) El pago de $237.605,28.** ¿Refleja plata que realmente salió de efectivo? Si en la realidad se pagó $196.368 (sin IVA), la recarga tiene que registrar el pago real.

---

## Orden de implementación propuesto

| # | Bloque | Por qué en este lugar |
|---|---|---|
| 0 | Backup programado (`backup-virikyna.ps1` en el Programador de tareas) + una prueba de restauración | Todo lo que sigue toca producción |
| 1 | **B — fix del refresh de sesión** (+ preguntar antes de reiniciar en Local) | Cambio chico, impacto alto, sin dependencias; frena la pérdida de datos durante el resto del trabajo |
| 2 | **F — alícuota de IVA en compras** (columna + RPC carga/edición + UI de las 3 apps + separar `IVA_DEFAULT`) | Requisito para G; separa la constante compartida con E |
| 3 | **G — borrar y recargar la factura** (backup antes) | Necesita F, para que el cupón entre exento |
| 4 | **E — IVA del producto** (switch + acción masiva) | Usa la constante ya separada en F; no depende de A ni de C |
| 5 | **D — RPC eliminar producto + RLS de productos** | Cierra el hueco de RLS; sirve para resolver los duplicados de C |
| 6 | **C — códigos** (filtro AIM + dígitos en la cámara, limpiar los 21, resolver los 2 duplicados con D, unificar el generador interno) | Necesita D para los duplicados |
| 7 | **A — normalización de texto** (triggers por tabla + limpieza de datos + búsquedas sin acento) | Es el más amplio: conviene después de resolver duplicados (C/D) y con la búsqueda ajustada en el mismo cambio para no romperla |
| 8 | **B — borradores persistentes** (factura de compra primero) | Después de F, porque el formulario de factura cambia en F y se haría dos veces |

Cada bloque que toque la base lleva su `docs/NN_*.sql` (desde el 44), probado con `BEGIN … ROLLBACK`, y backup previo.
