# 73 — Bandeja de documentos minimizados + estado por página

Virikyna Local y Virikyna Gestión. Sin cambios de base de datos.

## 1. Para qué

La dueña trabaja como en los sistemas viejos con subventanas minimizadas: abre una factura de
proveedor, la deja a medio cargar, va a Inventario a corroborar un dato, vuelve y la factura sigue
igual. Antes no se podía: los formularios y detalles son modales que tapan toda la pantalla (menú
incluido), así que había que cerrarlos para ir a otra pantalla.

Dos partes:

- **Bandeja (E):** ciertos modales se pueden **minimizar** a un chip del encabezado. Quedan abiertos
  mientras se navega y se restauran exactamente como estaban.
- **Estado por página (B parcial):** filtros, búsqueda, pestaña activa, orden, selección y scroll de
  algunas pantallas sobreviven a ir y volver desde el menú.

## 2. Qué se puede minimizar (v1)

| Documento | Dónde se abre | Clave (no se duplica) | Chip |
|---|---|---|---|
| Carga de factura / NC de compra (nueva, copia o borrador retomado) | Proveedores → Facturas | `factura_compra:nueva:<uuid>`, `:copia:<uuid>`, `:borrador:<id>` | "Factura · AGABELLA · 3 ítems" (o "NC · …") |
| Detalle de factura de compra | Proveedores → Facturas (fila o ⋮ Ver detalle) | `factura_compra:detalle:<id>` | "AGABELLA · Remito X 01-9762755" |
| Detalle de venta (Comprobante X / Factura C) | Facturación → Ventas del día y Facturación | `venta:<id>` | "Venta #1234" |
| Ficha de artículo (Datos / Historial de precio / Historial de movimientos) | Inventario (fila) | `producto:<id>` | "Art. PELOTA 20CM" |

**No entran:** pagos a proveedores, cobros a clientes, el alta de un producto nuevo y Ventas (Local),
que ya tiene sus tickets en espera. Un modal que se abre **adentro** de un documento (ConfirmDialog,
Registrar pago, Editar factura, "+ Crear producto nuevo", el original de una copia…) no se minimiza
solo: se oculta y vuelve junto con su documento.

## 3. Reglas

- **Máximo 5.** El 6.º muestra "Ya hay 5 documentos abiertos — cerrá alguno desde la barra de arriba"
  y no cierra ninguno.
- **Una clave por documento.** Abrir uno que ya está (la misma factura, el mismo artículo, el mismo
  borrador desde "Seguir editando") lo trae al frente.
- **Uno solo visible.** Restaurar uno minimiza el que estaba visible. Abrir uno nuevo, también.
- **Solo en memoria, solo en la sesión.** No se reabre al día siguiente; la lista de la bandeja no se
  guarda. Los borradores de factura (docs/54) siguen funcionando igual que antes, y el autoguardado
  sigue corriendo con la factura minimizada.
- **Cambiar de usuario / cerrar sesión:** primero la factura con cambios guarda su borrador, después
  la bandeja se vacía. El provider lleva la clave del usuario: otro usuario arranca siempre vacío.
- **Permisos:** cada documento lleva los roles de la pantalla que lo abrió. Si el rol del usuario
  cambia, el que no puede verlo sale de la bandeja (no se muestra ni se restaura).

## 4. Al restaurar

| Documento | Qué pasa |
|---|---|
| Carga de factura | Vuelve igual (campos, ítem con foco, scroll). Se conserva lo cargado; si en el inventario cambió el costo, el precio de venta, el estado o se eliminó un producto de los ítems, aparece el aviso **"Cambió algo mientras estaba minimizada"**. También se vuelve a revisar si el comprobante ya está cargado. |
| Detalle de factura | Se vuelven a pedir los datos **sin** pasar por "Cargando…": la tabla no se vacía y el scroll queda. |
| Detalle de venta | Se vuelve a leer la venta (pudo facturarse mientras tanto). Lo tipeado en Mail / WhatsApp queda. |
| Ficha de artículo | Si el artículo no cambió en la base (mismo `updated_at` y stock), queda exactamente igual. Si cambió y la ficha **no** tiene cambios sin guardar, se vuelve a armar con los datos de hoy, en la misma pestaña (el scroll de esa pestaña vuelve arriba). Si cambió y **hay** cambios sin guardar, no se pisa nada: aviso **"Cambió algo mientras estaba minimizado"** con lo que cambió (costo, precio, stock…) y "Si guardás, queda lo que ves en el formulario". |

El foco vuelve al último campo donde se estaba trabajando ("la misma fila seleccionada").

## 5. Cerrar

La ✕ del chip hace lo mismo que la ✕ del documento: sin cambios cierra directo; con cambios primero
muestra el documento y pregunta lo de siempre ("Guardar borrador / Descartar / Seguir editando" en la
factura; "Cerrar sin guardar" en la ficha). Una factura ya guardada que muestra el aviso de contado o
la oferta de aplicar lo a cuenta termina como un guardado normal (el listado se actualiza).

## 6. Riesgos resueltos

- **Ventas (Local):** su teclado global (Enter = cobrar, letras al buscador) no actúa mientras haya un
  documento visible encima (`hayDocumentoVisible()`). Ventas no cambia en nada más.
- **Lector HID:** un documento minimizado queda con `visibility: hidden` + `aria-hidden` + sin clics:
  sus campos no pueden tomar el foco (ni por código), así que un escaneo nunca cae ahí.
- **GuardiaNavegacion:** un minimizado sale de la pila de `cambiosSinGuardar` y vuelve a entrar al
  restaurarlo: navegar no pregunta (no se pierde nada). Cerrar o recargar la pestaña de Gestión, y el
  "Reiniciar ahora" de la actualización de Local, sí preguntan (`hayDocumentosConCambios()`).
- **Ids repetidos:** con dos facturas o dos fichas abiertas había dos `<form id="…">` iguales en el
  DOM y "Guardar" podía enviar el oculto. La planilla de factura, Editar factura y las fichas de
  artículo de las dos apps usan ids propios (`useId`).

## 7. Cómo se ve

- Chips en el header de 64 px, en el espacio libre entre el botón del menú (Gestión) y las píldoras
  de usuario. No le sacan alto al área de trabajo.
- Chip: ícono por tipo + texto (DM Sans `label-bold`, `accent-darker`), 44 px de alto, borde teal
  (`accent`, #3FB9B9), entre 160 y 240 px de ancho, texto truncado con `title`. Punto teal si tiene
  cambios sin guardar. El visible se marca con fondo `accent-light` (`aria-pressed`).
- Dos botones por chip: el chip ("Restaurar Factura · AGABELLA · 3 ítems (con cambios sin guardar)")
  y su ✕ ("Cerrar …"). Navegables con Tab, foco visible.
- Si no entran: botón "+N" (o "N abiertos" si no entra ninguno) con un desplegable de los demás.
  A 1366 px con el menú abierto entran 2 chips; con el menú cerrado, 3; en Local a 1024 px, "2 abiertos".
- En el modal, "Minimizar" (ícono −) junto a la ✕. Con un documento visible, el fondo oscuro tapa
  también la barra: para cambiar de documento, primero se minimiza.

## 8. Estado por página (B parcial)

En la URL (`?tab=&desde=&q=…`) y recordado en la sesión (`sessionStorage`), mismo patrón que los
filtros de Inventario: recargar o volver desde el menú cae donde se dejó; un link con parámetros
manda sobre lo recordado. Hook `useParamsPagina` / `useBusquedaPagina` (`packages/shared/lib/estadoPagina.ts`).

| Pantalla | Qué se conserva |
|---|---|
| Facturación (Local y Gestión) | Pestaña; filtros desde, hasta, estado, medio de pago, búsqueda (y "Con notas" en Gestión) |
| Proveedores (Local y Gestión) | Pestaña; búsqueda de la lista de proveedores |
| Caja Gestión, Egresos (Gestión) | Pestaña |
| Historial y Auditoría (Gestión) | Usuario, tabla, acción, desde, hasta |
| Inventario (Local y Gestión) | Orden, selección (checkboxes) y scroll — en memoria de la sesión, no en la URL |

Todo se olvida al cambiar de usuario (`olvidarEstadoPaginas`).

**Formularios de página con aviso:** Registrar egreso y Movimientos manuales (Gestión) quedan en
`cambiosSinGuardar` mientras tengan algo cargado: ir a otra pantalla, cambiar de pestaña, Atrás o
cerrar la pestaña preguntan "Salir sin guardar / Seguir acá" (`useAvisoSalidaSinGuardar`).

## 9. Implementación

- `packages/shared/src/components/documentos/contexto.ts`: contexto por documento, hooks
  (`useDocumento`, `useDocumentoOculto`, `useAlRestaurar`, `useAliasDocumento`) y el estado global
  (`hayDocumentoVisible`, `hayDocumentosConCambios`).
- `…/documentos/DocumentosAbiertos.tsx`: provider (`DocumentosAbiertosProvider`, `useBandeja`) y chips
  (`BandejaDocumentos`). Montados en las dos `AppShell`, fuera del `<Outlet/>`.
- `Modal` (shared): props `minimizable` y `etiquetaBandeja`. Lee el contexto: minimizado → invisible,
  sin foco atrapado, fuera de `cambiosSinGuardar`. El raíz reporta el chip y registra cómo cerrarse.
- `…/documentos/ComprobanteVentaDocumento.tsx`, `…/documentos/ProductoDocumento.tsx` y
  `apps/*/src/pages/Proveedores/documentosFactura.tsx`: cómo se abre cada documento.
- Avisos al listado: `packages/shared/lib/cambiosDatos.ts` (`avisarCambioDatos` / `useAlCambiarDatos`).
  Se eligió un evento y no `invalidateQueries` porque esos listados (facturas de compra, borradores,
  productos) cargan con `useState` + `useEffect`, no con React Query. El documento vive en AppShell y
  la página que lo abrió puede haberse desmontado: el listado montado, si hay, se recarga; si no hay
  ninguno, lee datos frescos al montarse.
- `armarDatosComprobanteVenta` (lib/comprobante.ts) reemplaza las tres copias del armado del
  comprobante (Facturación de Local y Gestión, Ventas del día).

## 10. Pendiente / fuera de la v1

- Pagos a proveedores y cobros a clientes como documentos.
- Panel lateral de consulta rápida de producto (opción D del diagnóstico).
- Con un documento visible no se puede tocar la barra (queda debajo del fondo oscuro).
