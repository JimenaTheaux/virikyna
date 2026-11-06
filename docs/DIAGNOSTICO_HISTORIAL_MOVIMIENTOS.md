# Diagnóstico — Historial de movimientos del producto (Gestión y Local)

**Fecha:** 2026-11-05 · **Solo diagnóstico:** no se tocó código, schema ni datos.

**Fuentes:**
- Schema: `backups/virikyna_2026-11-05_pre-docs68-test/schema.sql` (backup de prod de hoy 18:21). Las líneas `schema:NNNN` de abajo son de ese archivo. `supabase/schema/schema.sql` del repo está desactualizado y no se usó.
- Datos: consultas **de solo lectura** (`SELECT`) contra prod el 2026-11-05 a la noche. Los scripts están en el scratchpad de la sesión (`q1_conciliacion.sql` … `q5.sql`) y se pueden volver a correr.
- Código: rama `lote-oct-2026` (commit 80ab306).

---

## Resumen

1. **El stock cuadra al 100 %.** En los 2355 productos con stock, `stock_ubicaciones` es igual a la suma de `movimientos_stock`, sin ninguna diferencia. Los 9 productos restantes son altas recientes, sin stock y sin movimientos. Se puede mostrar el "stock resultante" fila por fila y termina en el stock actual sin inventar nada.
2. **Ningún camino de la app cambia stock sin dejar movimiento.** `stock_ubicaciones` y `movimientos_stock` no tienen policies de escritura. Solo escriben RPCs `SECURITY DEFINER`, y todas insertan el movimiento junto con el cambio de stock. El único hueco real son los **scripts SQL manuales**: el borrado de prueba de docs/46 (19/10) y otro borrado del 22/10. Esos scripts borraron el movimiento y revirtieron el stock al mismo tiempo, así que el neto quedó en cero.
3. **El tipo técnico no alcanza para etiquetar.** `tipo` tiene solo 4 valores (`venta`, `compra`, `ajuste`, `inicial`). Anulaciones de venta y de compra, devoluciones, cambios, devoluciones a proveedor, ajustes manuales y reversiones caen todos en `ajuste`. Hoy se distinguen por `referencia_id` (a qué tabla apunta) más el texto de `motivo`. Con los datos actuales la clasificación es determinística (se verificó con conteos), pero depende de textos.
4. **El depósito no se usa.** Todo el stock y todos los movimientos están en `local`. Se recomienda mostrar el stock total.
5. **El volumen es chico.** Promedio de 1,4 movimientos por producto y máximo 77 (FIGURITAS MUNDIAL FIFA). Contando precio y datos, el peor caso ronda las 100 filas. No hace falta paginar del lado del servidor.
6. **Hallazgo de negocio:** la "corrección de cantidad" de la carga inicial (`carga_inicial_editar_producto`) se sigue usando como ajuste de stock **hasta el 03/11**: 239 correcciones en 182 productos. **Fija la cantidad absoluta** (ej. `-10 → 11`) y no pide motivo. Ver D7.
7. **El historial de precio actual** (pestaña existente) lee `auditoria`, que solo pueden leer admins, y está **duplicado** en cada app. No usa `productos_precios_historial`.

---

## Parte 1 — Relevamiento

### 1. Modal de detalle de producto

| App | Archivo | Pestañas |
|---|---|---|
| Gestión | [ProductoFormModal.tsx](../apps/virikyna-gestion/src/pages/Inventario/ProductoFormModal.tsx) | Estado `tab: 'datos' \| 'historial'` ([L96](../apps/virikyna-gestion/src/pages/Inventario/ProductoFormModal.tsx#L96)). Botones de pestaña escritos a mano dentro del modal ([L300-L325](../apps/virikyna-gestion/src/pages/Inventario/ProductoFormModal.tsx#L300-L325)). Footer de Guardar solo en Datos ([L267](../apps/virikyna-gestion/src/pages/Inventario/ProductoFormModal.tsx#L267)). |
| Local | [ProductoFormSheet.tsx](../apps/virikyna-local/src/pages/Inventario/ProductoFormSheet.tsx) | Igual a Gestión, pero las pestañas y el fetch **solo existen para admin** (`esAdmin`, [L142](../apps/virikyna-local/src/pages/Inventario/ProductoFormSheet.tsx#L142), [L322](../apps/virikyna-local/src/pages/Inventario/ProductoFormSheet.tsx#L322), [L349](../apps/virikyna-local/src/pages/Inventario/ProductoFormSheet.tsx#L349)). El cajero no ve pestañas. |
| Inventario (PWA) | [ProductoFormSheet.tsx](../apps/virikyna-inventario/src/pages/Inventario/ProductoFormSheet.tsx) | Sin pestañas ni historial. Queda fuera del alcance pedido. |

- **Historial de precio:** el componente [HistorialPrecioTab.tsx](../apps/virikyna-gestion/src/pages/Inventario/HistorialPrecioTab.tsx) está **duplicado**: la copia de Local ([HistorialPrecioTab.tsx](../apps/virikyna-local/src/pages/Inventario/HistorialPrecioTab.tsx)) difiere solo en un comentario. Es una tabla simple con estilo viejo (no sigue §5.2 de docs/08: no tiene `rounded-xl`, header `bg-accent-light` ni `table-row`). Columnas: Fecha, Usuario, Costo, Margen 1, Margen 2, Precio de venta (antes → después).
- **Datos del historial de precio:** un solo fetch a `auditoria` (`tabla_afectada='productos'`, `accion='edicion'`), filtrado en el cliente por [historialPrecio.ts](../packages/shared/lib/historialPrecio.ts) (`historialDeMargen`). Solo cuentan los cambios de `costo`, `margen_1`, `margen_2` y `precio_manual`. **No incluye** cambios de precio por IVA ni el precio del alta, y no usa `productos_precios_historial`.
- **Nombres de usuario:** [perfiles.ts](../packages/shared/lib/perfiles.ts) `nombresPorId` → vista `perfiles_publico`.
- **Stock en la ficha:** recuadro "Stock por ubicación" con Local y Depósito más el botón "Ajustar" ([L530-L560](../apps/virikyna-gestion/src/pages/Inventario/ProductoFormModal.tsx#L530-L560)).
- **Piezas compartidas que se pueden reusar** (`packages/shared/src/components/`): `Modal`, `EstadoBadge` (amber/green/red/neutral/violet), `MostrarMas` (`PAGINA_LISTA = 25`), `ControlSegmentado`, `RowActionsMenu`, `DevolucionDetalleModal`, `ComprobanteModal`. Para abrir una factura de compra por id: `useFacturaCompraPorId` ([facturasCompra.ts:647](../packages/shared/lib/facturasCompra.ts#L647)) más `FacturaCompraDetallePorId`, que existe **en cada app** ([Gestión](../apps/virikyna-gestion/src/pages/Proveedores/FacturaCompraDetallePorId.tsx), [Local](../apps/virikyna-local/src/pages/Proveedores/FacturaCompraDetallePorId.tsx)). **No hay** un loader "venta por id → DatosComprobante": `ComprobanteModal` recibe los datos armados desde cada pantalla.
- **No existe** un componente de pestañas compartido: cada modal arma las suyas.

### 2. `movimientos_stock` (schema:5618)

| Columna | Tipo | Nota |
|---|---|---|
| `id` | uuid (gen_random_uuid) | Aleatorio: no sirve para ordenar. |
| `producto_id` | uuid NOT NULL → productos | |
| `ubicacion` | enum `ubicacion_stock` (`local`, `deposito`) (schema:317) | |
| `tipo` | enum `tipo_movimiento_stock` (`venta`, `compra`, `ajuste`, `inicial`) (schema:305) | |
| `cantidad` | numeric(10,2) NOT NULL | **Con signo**: + entra, − sale. |
| `motivo` | text | Pasa por `fn_sin_acentos` (sin tildes). |
| `referencia_id` | uuid, **sin FK** | Apunta a tablas distintas según el caso (abajo). |
| `usuario_id` | uuid NOT NULL → perfiles | Siempre presente (0 nulos). |
| `created_at` | timestamptz default now() | Fecha y hora. Dentro de una transacción es el mismo instante para todas las filas. |

- **No guarda stock resultante.** Hay que calcularlo.
- Triggers: `trg_auditoria_movimientos_stock` (copia cada INSERT a `auditoria`) y `trg_sin_acentos`.
- Índice único útil: `idx_movimientos_stock_producto (producto_id)`. **No hay** `(producto_id, created_at)`.

**A qué apunta `referencia_id`** (verificado contra los datos):

| tipo | referencia_id → | En prod |
|---|---|---|
| `venta` | `ventas.id` | 560 / 560 |
| `compra` | `facturas_compra.id` | 233 / 233 |
| `ajuste` | `ventas.id` (anulación de venta), `facturas_compra.id` (anulación de compra, NC con devolución), `devoluciones.id` (devolución, cambio, anulación de devolución), o NULL (ajuste manual o reversión) | 23 a facturas, 2 a devoluciones, 9 NULL |
| `inicial` | `carga_inicial_items.id`, que **se borra** al finalizar la carga. El id sobrevive en `carga_inicial_operaciones.item_id`. Sin comprobante para abrir. NULL en las correcciones. | 2208 con ref, 256 NULL |

### 3. Quién escribe stock

**Todo camino que modifica `stock_ubicaciones` deja movimiento**, salvo los scripts manuales. No hay policies de INSERT/UPDATE/DELETE sobre `stock_ubicaciones` ni sobre `movimientos_stock`: desde el cliente solo se lee ([Gestión L180](../apps/virikyna-gestion/src/pages/Inventario/ProductoFormModal.tsx#L180), [Local L203](../apps/virikyna-local/src/pages/Inventario/ProductoFormSheet.tsx#L203), Inventario L156).

| Camino | RPC (schema) | tipo / motivo | ref | Mov. |
|---|---|---|---|---|
| Venta | `confirmar_venta` (2007, mov. L2132) | `venta`, −cant, sin motivo | venta | ✔ |
| Anulación de venta | `anular_venta` (651) | `ajuste` +cant, "Reposicion por anulacion de venta: …" | venta | ✔ |
| Devolución: ítem devuelto que reingresa | `crear_devolucion` (2150, L2342) | `ajuste` +cant, "Devolucion de venta #N (motivo)" | devolución | ✔ |
| Devolución: ítem defectuoso | ídem | No toca stock (queda en `devolucion_items` con `reingresa_stock=false`) | — | n/a |
| Cambio: producto entregado | ídem (L2364) | `ajuste` −cant, "Cambio sobre venta #N" | devolución | ✔ |
| Anulación de devolución | `anular_devolucion` (530) | `ajuste` ±, "Anulacion de devolucion #N: …" | devolución | ✔ |
| Factura de compra (a cuenta y contado) | `cargar_factura_compra` (1528, L1664); `cargar_factura_compra_contado` (1748) la llama | `compra` +cant, sin motivo, en la ubicación del ítem | factura | ✔ |
| NC con devolución de mercadería | `cargar_factura_compra` (L1673) | `ajuste` −cant, "Devolucion a proveedor: NC …". Hace UPDATE directo, pero antes valida que haya stock. | NC | ✔ |
| Vincular ítem de factura después | `vincular_item_factura_compra` (4842) | `compra` +cant, "Item de factura vinculado despues de cargar…" | factura | ✔ |
| Anulación de factura de compra | `anular_factura_compra` (581) | `ajuste`, revierte el neto por producto y ubicación, "Anulacion de factura de compra: …" | factura | ✔ |
| Edición de factura de compra | `editar_factura_compra` (2561) | Solo cabecera: no toca ítems ni stock | — | n/a |
| Ajuste manual (admin) | `ajustar_stock` (487) | `ajuste` ±, motivo obligatorio | NULL | ✔ |
| Reversión de ajuste (Historial de Gestión) | `revertir_movimiento` (4587) | `ajuste` contrario, "Reversion de ajuste (auditoria)" | NULL | ✔ |
| Carga inicial: finalizar | `carga_inicial_finalizar` (1144, L1235) | `inicial` +cant, "Carga inicial" | ítem del borrador | ✔ |
| Carga inicial: corregir cantidad | `carga_inicial_editar_producto` (1041, L1096) | `inicial` delta, "Carga inicial: correccion de cantidad (A → B)". **Fija un valor absoluto.** | NULL | ✔ |
| Eliminar producto | `eliminar_producto` (2727) | Borra los movimientos `inicial` y el stock. Solo se permite sin otros movimientos. El producto desaparece. | — | n/a |
| Alta de producto (formulario) | INSERT directo en `productos` | No crea stock (queda sin fila, stock 0) | — | n/a |
| Actualización masiva de precios / IVA | `actualizar_precios_masivo` (419), `fijar_iva_productos`, `marcar_iva_productos` | No tocan stock | — | n/a |
| Transferencia local ↔ depósito | **No existe** | — | — | — |
| **Scripts SQL manuales** | docs/46 (19/10), borrado del 22/10, docs/63 FAYDI, "Revierte la correccion…" (27/10) | Ver punto 8 | — | ⚠ depende del script |

Además, `trg_auditoria_stock_ubicaciones` copia cada **UPDATE** de `stock_ubicaciones` a `auditoria` (los INSERT no). Ese rastro es el que permitió detectar los scripts del punto 8.

### 4. Ubicaciones

- Hay dos ubicaciones en el enum: `local` y `deposito`. En prod **todo está en `local`**: 2355 filas de stock, 3291 movimientos, 0 filas de depósito con cantidad.
- El stock del producto es la suma de sus filas por ubicación (así lo calculan `productos_stock_bajo` y `dashboard_ventas_por_producto`).
- Solo los ítems de factura de compra y el ajuste manual pueden elegir depósito. Venta, devolución y carga inicial usan siempre `local`.
- **Recomendación:** mostrar el **stock resultante total** y la ubicación como un dato chico en la fila, solo si es depósito. Ver D1.

### 5. Precios — `productos_precios_historial` (schema:5777)

- Columnas: `id` (identity, sirve para ordenar), `producto_id`, `precio_anterior`, `precio_nuevo` (precio de venta final), `origen`, `usuario_id`, `created_at`. No guarda costo ni márgenes.
- Lo llenan `trg_precio_historial_ins` (INSERT → origen `alta`) y `trg_precio_historial_upd` (solo cuando cambia `precio_venta`), con la función `fn_productos_precio_historial` (schema:2935). El origen sale de `virikyna.origen_precio`: `factura` (cargar_factura_compra) o `masivo` (actualización por %). Si no viene, se deduce: `reversion`, `iva`, `margen` o `manual`.
- En prod: 405 filas en 217 productos (máximo 7 por producto). `alta` 200 (desde el 20/10), `factura` 145, `manual` 42, `margen` 18. `masivo`, `iva` y `reversion`: 0.
- **Hueco:** 2164 productos no tienen la fila `alta`, porque se crearon antes de que existiera el trigger de INSERT. No se perdió ningún *cambio*: hay 205 cambios de precio en `auditoria` y ninguno es anterior al primer registro del historial (17/10). El precio del alta de esos 2164 sí está en `auditoria` (alta con `precio_venta`, 2365 de 2365). Ver Parte 2.2.
- RLS: lo lee cualquier usuario activo (admin y cajero).

### 6. Auditoría (schema:4966, trigger genérico schema:2905)

- Columnas: `tabla_afectada`, `registro_id`, `accion` (`alta`, `edicion`, `eliminacion`, `anulacion`, `reversion`, `nota_correccion`), `valores_anteriores` y `valores_nuevos` (**la fila completa en JSON, antes y después**, no un diff), `usuario_id`, `revierte_auditoria_id`, `nota`, `created_at`.
- `trg_auditoria_productos`: INSERT, UPDATE y DELETE de `productos`, todas las columnas (costo, margen_1, margen_2, iva_porcentaje, precio_manual, nombre, marca, descripción, código, proveedor, stock mínimo, estado; además `precio_venta` y `precio_calculado`, que son derivados). Se saltea con `virikyna.suppress_audit` (lo usan `revertir_alta` y `revertir_edicion`, que después escriben su propia fila `reversion`).
- En prod, para `productos`: 2365 altas, 1333 ediciones y 1 eliminación, todas con usuario. Campos cambiados en las ediciones: iva_porcentaje 502 (todos el **24/10**, docs/62, y ninguno cambió el precio), nombre 472 (220 el 21/10 y 98 el 15/10: normalizaciones en lote), costo 191, precio_venta 205, proveedor 110, descripción 106, stock_minimo 49, margen_1 29, margen_2 22, código 23, precio_manual 20, marca 15, estado 3. Hay **32 ediciones sin ningún cambio real** (solo `updated_at`).
- Índice: `idx_auditoria_tabla_registro (tabla_afectada, registro_id)`, alcanza.
- RLS: **solo admin** (`auditoria_select_solo_admin`).

### 7. Usuario

- Cada fuente guarda `usuario_id` (→ `perfiles.id`). `movimientos_stock.usuario_id` es NOT NULL. En precios y auditoría puede ser NULL (1 caso en auditoría de stock, del script del 19/10).
- `perfiles` solo deja leer la fila propia (`perfil_propio`). Los nombres de otros usuarios salen de **`perfiles_publico`** (id y nombre), que **filtra `activo = true`**. Un usuario dado de baja aparece sin nombre. Hoy hay 2 cajeros inactivos, con 0 movimientos de stock, así que todavía no pasa, pero va a pasar. Ver D6.

### 8. Consistencia de los datos reales (todos los productos, no una muestra)

| Medida | Valor |
|---|---|
| Productos | 2364 (2363 activos) |
| Con stock o movimientos | 2355 |
| **Cuadran (stock = Σ movimientos, por ubicación)** | **2355 (100 %)** |
| No cuadran | 0 |
| Sin fila de stock y sin movimientos | 9, todos altas del 01/11 al 05/11 sin stock cargado (ej. "INFLABLE CHALECO TELA") |
| Con stock negativo | 4 (−1 o −2: AUTO CARS A FRICCION, BARRAL DE JUGUETES…, MIX DE CHARMS FOOD, CAMIONCITO TRUCK). Cuadran: son ventas sin stock suficiente, no errores de registro. |
| Primer movimiento | 13/10 18:00, igual que el primer producto. **No hay historia previa sin registrar.** |

**Por qué cuadra a pesar de la limpieza.** Se buscaron UPDATEs de `stock_ubicaciones` (por auditoría) sin un movimiento del mismo producto en el mismo instante. Aparecieron 4, en dos pares que se cancelan:
- SQUISHY BUTTER MANTECA: 1 → 25 el 17/10 (factura de prueba de CARLEVARIS) y 25 → 1 el 19/10 a las 21:34 hora de Argentina (20/10 00:34 UTC), sin usuario. Es **docs/46** (borrado de la factura de prueba), que borró también el movimiento `compra +24`.
- Un producto pasó de 37 → 38 → 37 el 22/10 a las 02:43 y 02:46 (usuario Jimena), junto con una eliminación de `facturas_compra` a las 02:46. Fue una factura borrada junto con su movimiento. *A verificar qué script fue.*

En los dos casos el movimiento y el stock se borraron juntos, así que el historial **no va a mostrar** esas facturas de prueba. Es lo correcto.

**Otras rarezas que no rompen la cuenta:**
- 16 movimientos `inicial` del 16 y 17/10 (usuario Jose) con `motivo` NULL y **sin fila en auditoría**: los insertó una versión vieja de la RPC o un script. *A verificar.* Se etiquetan como "Carga inicial".
- 14 movimientos `compra` con motivo "Correccion factura FAYDI 0011-33182…" (script de docs/63).
- 1 movimiento `inicial` "Revierte la correccion de cantid…" del 27/10, también de un script manual.
- 10 grupos (23 filas) con varios movimientos del mismo producto en el **mismo instante**, la misma transacción (ej. el producto dos veces en una venta). El orden dentro del grupo no está definido. Ver Parte 2.5.

### 9. Volumen

| Fuente | Promedio por producto | p95 | p99 | Máx |
|---|---|---|---|---|
| movimientos_stock | 1,4 | 3 | 5 | 77 |
| productos_precios_historial | 1,9 (217 productos) | — | — | 7 |
| auditoria (productos) | 1,6 | — | — | 15 |

Peor caso de la línea de tiempo: ~100 filas. Conviene traer **todo el historial en una llamada** (el saldo acumulado lo necesita igual) y paginar solo la vista con `MostrarMas` de a 25.

### 10. Permisos y RLS

| Tabla | Política SELECT | Admin (Gestión y Local) | Cajero (Local) |
|---|---|---|---|
| `movimientos_stock` | perfil activo | ✔ | ✔ |
| `stock_ubicaciones` | perfil activo | ✔ | ✔ |
| `productos_precios_historial` | perfil activo (authenticated) | ✔ | ✔ |
| `auditoria` | **solo admin** | ✔ | ✘ |
| `ventas`, `venta_items`, `facturas_compra`, `facturas_compra_items`, `devoluciones` | perfil activo | ✔ | ✔ (el cajero ve totales y costos de facturas de compra) |
| `perfiles` | fila propia | → `perfiles_publico` | → `perfiles_publico` |

Gestión es solo para admins (docs/02). En Local hoy el cajero no ve ninguna pestaña de historial.

---

## Parte 2 — Propuesta (no implementar)

### 2.1 Fuente de datos: RPC `historial_producto`

Se propone una función `LANGUAGE sql STABLE SECURITY INVOKER`, para que la RLS de cada tabla decida qué ve cada rol: el cajero no recibe las filas de `auditoria` sin que haya que programarlo. Devuelve la línea de tiempo completa y ya clasificada. El saldo acumulado se calcula sobre **todos** los movimientos y **después** se aplican los filtros, así el stock resultante no cambia al filtrar.

```sql
-- TENTATIVO. Número de doc a definir al implementar (otra sesión tiene docs/68 en prueba).
CREATE OR REPLACE FUNCTION public.historial_producto(
  p_producto_id uuid,
  p_desde timestamptz DEFAULT NULL,
  p_hasta timestamptz DEFAULT NULL,
  p_clases text[] DEFAULT NULL          -- NULL = todas
) RETURNS TABLE (
  fecha timestamptz, orden bigint, clase text, detalle text,
  ubicacion public.ubicacion_stock, cantidad numeric, stock_resultante numeric,
  usuario_nombre text, ref_tabla text, ref_id uuid, ref_numero text,
  precio_anterior numeric, precio_nuevo numeric, cambios jsonb
)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
WITH mov AS (
  SELECT m.*, v.numero AS venta_num, f.id AS fc_id,
         concat_ws(' ', f.tipo_comprobante, f.letra, f.punto_venta || '-' || f.numero_comprobante) AS fc_num,
         d.numero AS dev_num
  FROM movimientos_stock m
  LEFT JOIN ventas v           ON v.id = m.referencia_id
  LEFT JOIN facturas_compra f  ON f.id = m.referencia_id
  LEFT JOIN devoluciones d     ON d.id = m.referencia_id
  WHERE m.producto_id = p_producto_id
),
clasif AS (
  SELECT mov.*, CASE
    WHEN tipo = 'venta'                                               THEN 'venta'
    WHEN tipo = 'compra' AND motivo ILIKE 'Correccion factura%'       THEN 'compra_correccion'
    WHEN tipo = 'compra'                                              THEN 'compra'
    WHEN tipo = 'inicial' AND referencia_id IS NULL AND motivo IS NOT NULL THEN 'carga_inicial_correccion'
    WHEN tipo = 'inicial'                                             THEN 'carga_inicial'
    WHEN venta_num IS NOT NULL                                        THEN 'anulacion_venta'
    WHEN dev_num IS NOT NULL AND motivo ILIKE 'Anulacion de devolucion%' THEN 'anulacion_devolucion'
    WHEN dev_num IS NOT NULL AND cantidad > 0                         THEN 'devolucion_cliente'
    WHEN dev_num IS NOT NULL                                          THEN 'cambio_entrega'
    WHEN fc_id IS NOT NULL AND motivo ILIKE 'Devolucion a proveedor%' THEN 'devolucion_proveedor'
    WHEN fc_id IS NOT NULL                                            THEN 'anulacion_compra'
    WHEN motivo ILIKE 'Reversion de ajuste%'                          THEN 'reversion_ajuste'
    ELSE 'ajuste_manual' END AS clase
  FROM mov
),
dif AS (  -- stock actual − Σ movimientos (hoy 0 en todos los productos)
  SELECT COALESCE((SELECT sum(cantidad) FROM stock_ubicaciones WHERE producto_id = p_producto_id), 0)
       - COALESCE((SELECT sum(cantidad) FROM movimientos_stock  WHERE producto_id = p_producto_id), 0) AS d
),
stock AS (
  SELECT c.created_at AS fecha, c.clase, c.motivo AS detalle, c.ubicacion, c.cantidad,
         (SELECT d FROM dif) + sum(c.cantidad) OVER (ORDER BY c.created_at, c.id) AS stock_resultante,
         c.usuario_id,
         CASE WHEN c.venta_num IS NOT NULL THEN 'venta' WHEN c.fc_id IS NOT NULL THEN 'factura_compra'
              WHEN c.dev_num IS NOT NULL THEN 'devolucion' END AS ref_tabla,
         CASE WHEN c.venta_num IS NOT NULL OR c.fc_id IS NOT NULL OR c.dev_num IS NOT NULL THEN c.referencia_id END AS ref_id,
         COALESCE(c.venta_num::text, c.fc_num, c.dev_num::text) AS ref_numero
  FROM clasif c
),
sin_registro AS (  -- solo si algún día no cuadra: fila al principio, nunca un dato inventado
  SELECT p.created_at AS fecha, 'sin_registro'::text AS clase,
         'Diferencia entre el stock y los movimientos registrados'::text AS detalle,
         NULL::ubicacion_stock AS ubicacion, dif.d AS cantidad, dif.d AS stock_resultante
  FROM productos p, dif WHERE p.id = p_producto_id AND dif.d <> 0
),
precio AS (
  SELECT h.created_at AS fecha, h.id AS orden, 'precio'::text AS clase, h.origen AS detalle,
         h.precio_anterior, h.precio_nuevo, h.usuario_id
  FROM productos_precios_historial h WHERE h.producto_id = p_producto_id
),
datos AS (  -- RLS: el cajero recibe 0 filas
  SELECT a.created_at AS fecha, 'datos'::text AS clase, a.usuario_id,
         (SELECT jsonb_object_agg(k, jsonb_build_array(a.valores_anteriores -> k, a.valores_nuevos -> k))
          FROM unnest(ARRAY['costo','margen_1','margen_2','iva_porcentaje','nombre','marca',
                            'codigo_barras','descripcion','proveedor_id','stock_minimo','estado']) k
          WHERE a.valores_anteriores -> k IS DISTINCT FROM a.valores_nuevos -> k) AS cambios
  FROM auditoria a
  WHERE a.tabla_afectada = 'productos' AND a.registro_id = p_producto_id AND a.accion = 'edicion'
),
alta AS (
  SELECT p.created_at AS fecha, 'alta'::text AS clase,
         (SELECT a.usuario_id FROM auditoria a WHERE a.tabla_afectada = 'productos'
            AND a.registro_id = p.id AND a.accion = 'alta' LIMIT 1) AS usuario_id   -- NULL para el cajero
  FROM productos p WHERE p.id = p_producto_id
)
-- UNION ALL de stock / sin_registro / precio / datos (WHERE cambios IS NOT NULL) / alta.
-- Las filas sin cantidad toman el último stock_resultante con fecha <= la suya (LATERAL … ORDER BY fecha DESC LIMIT 1).
-- Nombre de usuario: LEFT JOIN perfiles_publico. Filtros p_desde, p_hasta y p_clases al final.
-- ORDER BY fecha DESC, orden DESC.
$$;
```

**El resumen** (stock actual, entradas, salidas, último movimiento) se puede sacar de la misma respuesta en el cliente, o de una segunda función `resumen_historial_producto`. El stock actual siempre sale de `stock_ubicaciones`, nunca del filtro. Ver D3 para qué cuenta como "entrada".

### 2.2 Huecos y cómo cerrarlos

**De acá en adelante:**
1. **Guardar la clase en el movimiento** en vez de deducirla de `motivo`. Se propone una columna `movimientos_stock.origen text` con CHECK sobre las clases de 2.3, que cada RPC de la tabla de §3 complete. Backfill de una sola vez con el CASE de arriba: hoy clasifica las 3291 filas sin ambigüedad, verificado. Así la RPC deja de depender de textos que pueden cambiar (y que `fn_sin_acentos` modifica).
2. **Regla para los scripts:** todo script de datos que toque stock pasa por `movimientos_stock`, con un movimiento compensatorio y motivo claro, y no borra movimientos. Solo se borran en un caso como docs/46, con la decisión explícita de "como si nunca hubiera existido". Agregar a `docs/37_chequeos_salud.sql` la conciliación del punto 8 (`stock_ubicaciones` contra la suma de movimientos) para detectar un desvío el mismo día.
3. **Corrección de carga inicial** (D7): decidir si sigue disponible. Si sigue, que pida motivo y quede etiquetada como ajuste.

**Para el pasado:**
- **Stock:** no hace falta ningún saldo inicial, porque todo cuadra. La fila `sin_registro` queda como resguardo: aparece solo si `stock_ubicaciones` y la suma de movimientos difieren, con la diferencia exacta y sin usuario. Así el contador cierra con el stock actual sin inventar un movimiento.
- **Precio del alta:** 2164 productos no tienen la fila `alta` en `productos_precios_historial`. Hay dos opciones: (a) backfill desde `auditoria` (alta → `valores_nuevos.precio_venta`, `created_at` y `usuario_id` reales), o (b) que la RPC lea ese dato de `auditoria`, lo que lo dejaría invisible para el cajero. **Se recomienda (a):** son datos reales, no inventados. Ver D5.

### 2.3 Etiquetas visibles

La regla de color sigue docs/08 §5.2, que no permite paleta libre: verde = entra mercadería, rojo = anulación, ámbar = corrección o ajuste que pide atención, neutro = salida normal o alta, violeta = no es movimiento de stock (precio o datos). La dirección también se ve en la columna Cantidad, con el signo +/− y texto `ink` (no rojo, para que una venta no parezca un error).

| clase | Texto | Badge | Detalle / origen | Comprobante |
|---|---|---|---|---|
| `alta` | Alta del producto | neutral | — | — |
| `carga_inicial` | Carga inicial | neutral | — | — |
| `carga_inicial_correccion` | Corrección de carga inicial | amber | "de A a B" (sale del motivo) | — |
| `compra` | Compra | green | Proveedor y comprobante ("Factura A 0001-123") | Factura de compra |
| `compra_correccion` | Corrección de compra | amber | Motivo | Factura de compra |
| `anulacion_compra` | Anulación de compra | red | Motivo | Factura de compra |
| `devolucion_proveedor` | Devolución a proveedor | neutral | NC N° | Nota de crédito |
| `venta` | Venta | neutral | Venta N° | Venta (comprobante) |
| `anulacion_venta` | Anulación de venta | red | Venta N° y motivo | Venta |
| `devolucion_cliente` | Devolución de cliente | green | Venta N° y motivo | Devolución |
| `cambio_entrega` | Cambio (entregado) | neutral | Venta N° | Devolución |
| `anulacion_devolucion` | Anulación de devolución | red | Motivo | Devolución |
| `ajuste_manual` | Ajuste manual | amber | Motivo ("Rotura", "Corrección de conteo físico") | — |
| `reversion_ajuste` | Reversión de ajuste | amber | — | — |
| `sin_registro` | Diferencia sin registro | amber | Texto fijo | — |
| `precio` | Cambio de precio | violet | "$ A → $ B" y origen (Manual / Factura / Por % / Margen / IVA / Reversión) | Factura, si el origen es `factura` (a verificar: requiere vincular por instante) |
| `datos` | Cambio de datos | violet | "Costo $ A → $ B · Lleva IVA: no → sí · Nombre…" | — |

### 2.4 UI

- **Pestaña nueva** "Movimientos", en el mismo lugar que Datos e Historial de precio de los dos modales. Componente **único** en `packages/shared/src/components/inventario/HistorialMovimientosTab.tsx`, que recibe `supabase` y callbacks para abrir comprobantes, el mismo patrón que `useEliminarProducto`. Aprovechar para extraer las pestañas a un componente compartido y mover ahí también `HistorialPrecioTab`, que hoy está duplicado (D8).
- **Resumen arriba:** 4 tarjetas compactas (Stock actual · Entradas · Salidas · Último movimiento), con la etiqueta en `label-bold` uppercase y el número en `headline-md` (docs/08 §5). El stock actual destacado y en ámbar si es negativo.
- **Filtros:** `ControlSegmentado` o select de tipo (Todos / Entradas / Salidas / Ajustes / Precio y datos) y rango de fechas con los mismos inputs que Facturación. Al filtrar, el stock resultante de cada fila no cambia.
- **Tabla** estilo §5.2: `table-fixed` con `colgroup`. Columnas Fecha y hora (fija) · Movimiento (badge, fija) · Detalle/origen (variable, `[overflow-wrap:anywhere]`) · Usuario · Cantidad (fija, `tabular-nums`, +/−, vacía en precio/datos) · Stock (fija, `font-semibold`). Sin scroll horizontal; validar en 1024, 1280, 1366 y 1920 px.
- **Paginación:** todo en una llamada y `MostrarMas` de a 25 (`PAGINA_LISTA`).
- **Comprobante:** una sola acción por fila, como ícono suelto según la regla de §5.2, o la fila clickeable. Factura de compra → `FacturaCompraDetallePorId` (existe en las dos apps; se puede pasar como prop o mover a shared). Devolución → `DevolucionDetalleModal` (shared). Venta → hace falta un loader nuevo "venta por id → DatosComprobante" para `ComprobanteModal`. Modal encima de modal: verificar el foco atrapado (`dialogo`). *A verificar en prueba real.*
- **Local con cajero:** ver D2.

### 2.5 Riesgos y performance

- **Índice:** `CREATE INDEX idx_movimientos_stock_producto_fecha ON movimientos_stock (producto_id, created_at, id);`, que reemplaza a `idx_movimientos_stock_producto`. Con 3291 filas no es urgente, pero es barato. `auditoria` y `productos_precios_historial` ya tienen el índice que hace falta.
- **Orden estable:** el desempate por `id` (uuid aleatorio) es estable pero arbitrario dentro de una misma transacción. Solo afecta a 10 grupos y el saldo final es igual. Si molesta, agregar `orden bigint GENERATED ALWAYS AS IDENTITY` a `movimientos_stock`. *A verificar en una restauración local: el orden de llenado de las filas existentes.*
- **Clasificación por texto:** se rompe si cambia un `motivo` en una RPC. Se mitiga con la columna `origen` (2.2.1).
- **`CREATE OR REPLACE VIEW`** pierde `security_invoker` (ver la memoria del proyecto). Por eso se propone una función y no una vista.
- **Ruido en "Cambio de datos":** una factura deja tres filas al mismo tiempo (compra, precio, costo/proveedor), y las normalizaciones en lote del 15 y 21/10 (nombres) y del 24/10 (IVA) llenan la línea de tiempo. Ver D4.
- **Usuarios inactivos** sin nombre en `perfiles_publico`. Ver D6.

### 2.6 Fases sugeridas

1. **Base de datos (una migración):** índice, columna `origen` + backfill, RPC `historial_producto` (+ resumen), backfill de precios del alta (si D5 = sí), chequeo de conciliación en docs/37. Probar en una restauración local (`restaurar-prueba.ps1`), no con ROLLBACK, por el backfill y la columna nueva. Después, que cada RPC de §3 complete `origen`.
2. **Componente compartido:** pestañas compartidas, `HistorialMovimientosTab` (resumen, filtros, tabla, MostrarMas) y migrar `HistorialPrecioTab` a shared.
3. **Links a comprobantes:** loader de venta por id y uso de `FacturaCompraDetallePorId` / `DevolucionDetalleModal`.
4. **Integración en Gestión y en Local** (con el criterio de rol de D2), QA en los anchos de docs/08 y E2E sin escrituras (memoria de testing contra prod).

---

## Parte 3 — Decisiones para validar con la clienta

| # | Decisión | Recomendación |
|---|---|---|
| D1 | ¿Stock resultante total o por ubicación? | **Total.** El depósito no se usa: 0 movimientos. La ubicación se muestra solo si es depósito. |
| D2 | En Local, ¿el cajero ve la pestaña? ¿Qué parte? | Ver movimientos de stock y cambios de precio: **sí**, porque la RLS ya lo permite. Cambios de datos (costo, márgenes): **solo admin**, porque `auditoria` es solo admin. ¿El cajero puede abrir la factura de compra, que muestra costos? |
| D3 | ¿Qué suma en "Entradas" y "Salidas"? Una carga de 17000 corregida a 1 (DIDACTICO BEBE ALFOMBRA…, 13/10) infla las dos. | Entradas = compras + devoluciones de cliente + anulaciones de venta. Salidas = ventas + cambios + devoluciones a proveedor + anulaciones de compra. Carga inicial y sus correcciones → un "Stock inicial" neto aparte. Ajustes manuales → su propio total. |
| D4 | ¿Qué cambios de datos se muestran? | Costo, márgenes, IVA, proveedor, nombre, marca, código, estado y stock mínimo. Esconder las ediciones sin cambios (32) y juntar en la fila de la compra los cambios hechos por la misma factura. ¿Mostrar las normalizaciones en lote (21/10 nombres, 24/10 IVA) o filtrarlas? |
| D5 | ¿Completar el precio del alta de 2164 productos desde la auditoría? | **Sí.** Son datos reales con fecha y usuario reales. |
| D6 | Usuarios dados de baja: ¿se muestra su nombre? | Sí. Habría que exponer el nombre de usuarios inactivos para el historial (cambiar `perfiles_publico` o agregar una vista nueva; afecta otras pantallas). Alternativa: mostrar "Usuario dado de baja". |
| D7 | "Corrección de cantidad" de la carga inicial: se usa como ajuste hasta el 03/11, fija la cantidad absoluta (pisa las ventas del medio) y no pide motivo. | Cerrar la carga inicial y usar "Ajustar" (motivo obligatorio). Si se mantiene, pedir motivo. En el historial: "Corrección de carga inicial", en ámbar. |
| D8 | ¿La pestaña "Historial de precio" sigue aparte o se integra a "Movimientos"? | Mantenerla (muestra costo y márgenes en columnas) y pasarla a shared. Más adelante evaluar unirlas. |
| D9 | 4 productos con stock negativo (−1/−2): el historial los va a mostrar. | No es un error de registro: son ventas sin stock. ¿Ajustar con conteo físico? |
| D10 | ¿Entra la PWA de Inventario (celular)? | Fuera de alcance por ahora: el pedido es Gestión y Local. |

**A verificar en prueba real:** qué script hizo el borrado del 22/10; el origen de los 16 movimientos `inicial` sin auditoría (16 y 17/10); modal sobre modal al abrir comprobantes (foco y Esc); vincular el cambio de precio de origen `factura` con su comprobante por instante; el orden de llenado si se agrega `orden` identity.
