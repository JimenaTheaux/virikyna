# Diagnóstico — Cuentas corrientes de clientes + cuentas corrientes internas

**Fecha:** 2026-11-05 · **Tipo:** solo diagnóstico (no se tocó código, ni base, ni dependencias).
**Fuentes:** código del repo (rama `lote-oct-2026`, commit `80ab306`) y el schema/datos **vigentes** del backup de producción `backups/virikyna_2026-11-05_0753` (el `supabase/schema/schema.sql` del repo es del 08/10 y está desactualizado: no tiene `registrar_pago_proveedor_v3`, docs/58, 66, 67). Las líneas "dump:NNNN" refieren a `backups/virikyna_2026-11-05_0753/schema.sql`.

---

## 0. Cinco hallazgos que cambian el planteo

1. **No hay PowerSync ni SQLite.** Local va directo a Supabase igual que Gestión. Se evaluó y se descartó (`docs/05_stack_tecnico.md:29`). No hay reglas de sync ni conflictos offline que resolver: una edición en Gestión se ve en Local en cuanto Local vuelve a consultar.
2. **Hoy los únicos clientes son internos.** Producción tiene 5 clientes: GRION ALICIA, LOPEZ ANA JULIA (dueñas), ALBORNOZ ALEJANDRA, BARONTINI JOSE, MALDONADO BELEN (cajeros). Ningún cliente externo. `pagos_cliente` tiene **0 filas**.
3. **Ya hay una venta interna real, con un descuento que puso la propia empleada.** Venta N° 388 (04/11): clienta ALBORNOZ ALEJANDRA, **la cargó la cajera Ale**, 1 silla reposera FAYDI de $37.000 con **30 % de descuento global** → $25.900 a cta. cte. Es justo lo que este cambio busca ordenar (que el descuento lo decida la dueña y no quien compra). Hay que decidir qué hacer con esa venta (ver decisiones).
4. **El cobro a clientes tiene dos fallas de caja** (sin impacto todavía porque no hubo ningún cobro):
   - `registrar_pago_cliente` no tiene `origen`: **siempre** suma a la cuenta de Gestión, también un cobro en efectivo hecho en Local. Contradice la regla de docs/58 ("el efectivo de Local queda en Local y entra a Gestión solo por retiro"). Ya figura como pendiente en `docs/58_efectivo_local_no_impacta_gestion.sql:36-38`.
   - `cerrar_caja` no suma los cobros de clientes: un cobro en efectivo en Local entra al cajón pero **no** al efectivo esperado del Cierre Z → sobrante (dump:1858-2006).
5. **No hay costo histórico por venta.** `venta_items` no guarda costo; `productos_precios_historial` guarda solo precio de venta, no costo. El margen del modal tiene que salir del costo actual o de una aproximación (ver 2.5).

---

## Parte 1 — Relevamiento

### 1.1 Módulo Proveedores (Gestión, y compartido con Local)

| Pieza | Ruta | Rol |
|---|---|---|
| Página de detalle | `apps/virikyna-gestion/src/pages/Proveedores/ProveedorDetallePage.tsx:13-59` | Envoltorio fino: `origen="general"`, Editar/Anular, Copiar, aplicar a cuenta, enchufa su modal de detalle |
| Idem Local | `apps/virikyna-local/src/pages/Proveedores/ProveedorDetallePage.tsx:25-27` | `origen="turno"`, sin Editar/Anular |
| **Pantalla de cuenta corriente** | `packages/shared/src/components/ProveedorCuentaCorriente.tsx` (892 líneas) | Cabecera + 5 KPIs (saldo, pendientes, crédito NC, a cuenta, último pago) :354-387; pestañas Pendientes/Pagados/Todos/Pagos con teclado :61-66, :241-259, :390-410; filtros en la URL :112-140, :413-473; tabla con checkbox y "seleccionar todos" con indeterminado :261-278, :514-658; barra sticky de selección "Pagar" :662-690; tabla de pagos con lo que cubrió cada uno :782-892 |
| Modal de pago | `packages/shared/src/components/PagarProveedorModal.tsx` | Monto precargado con lo seleccionado; vista previa "Cómo se reparte" :334-412; un medio (Local, v2) o varios medios (Gestión, v3) :81-85, :158-184; aviso de pagos a cuenta :232-251 |
| Editor de varios medios | `packages/shared/src/components/MediosPagoEditor.tsx` + `packages/shared/lib/mediosPago.ts` | Filas de medio/monto, cheques con número/banco/fecha, generador 30/60/90, validación en centavos |
| Reparto (vista previa) | `packages/shared/lib/repartoPagoProveedor.ts` | Espejo en TS del RPC: elegidos o los más viejos, primero NC, sobrante a cuenta (con tests) |
| Aplicar pagos a cuenta | `packages/shared/src/components/AplicarACuentaModal.tsx`, `packages/shared/lib/pagosACuenta.ts` | Imputa después pagos que quedaron sin comprobante |
| Hooks | `packages/shared/lib/facturasCompra.ts` (`useProveedor`, `useComprobantesProveedor`, `usePagosProveedor`, `useRegistrarPagoProveedorV2/V3`, `invalidarCuentaProveedor`) | React Query, todo con nombres de proveedor |
| Tablas | `pagos_proveedor` (dump:5027), `pagos_proveedor_aplicaciones` (dump:5528: pago o NC → factura, `revertida_at`), `pagos_proveedor_medios` (dump:5055: medio, monto, cheque, `propio`) | |
| Vistas | `facturas_compra_saldo` (dump:5549: `total_aplicado`, `saldo_pendiente`, `credito_disponible`, `estado` pendiente/parcial/pagada/anulada), `proveedores_saldo` (dump:5826), `pagos_proveedor_a_cuenta` (dump:5679), `cartera_cheques_emitidos` | |
| RPCs | `registrar_pago_proveedor_v2` (dump:3984), `registrar_pago_proveedor_v3` (dump:4042), `aplicar_pagos_a_cuenta` (dump:765), `desaplicar_pago` (dump:2469) | v3 rechaza cheques de terceros: "Por ahora solo se registran cheques propios" (dump:4134) |

**Reutilizable tal cual:** la estructura visual de `ProveedorCuentaCorriente` (KPIs, tabs accesibles, filtros en URL, selección + barra sticky, tabla de pagos), `Modal`, `ConfirmDialog`, `RowActionsMenu`, `EstadoBadge`, `FormField`, la lógica de centavos de `mediosPago.ts` (`totalMedios`, `diferenciaMedios`) y el algoritmo de `repartoPagoProveedor.ts` (no depende de nada propio de proveedores salvo el nombre de tipos y la regla de NC).

**Acoplado a proveedores:** tipos `FacturaCompraSaldo`/`TipoComprobanteCompra`, NC de compra, filtros "Tipo"/"Compra (artículos/servicios)", Copiar/Editar/Anular factura, `ObservacionesProveedor`, márgenes en la cabecera, hooks y query keys, `FormaPagoEgreso` (efectivo/transferencia/cheque/echeq: es plata que **sale**), cheques **propios** y su cartera de emitidos.

### 1.2 Cuentas corrientes de clientes hoy (Gestión y Local)

- **Pantallas:** `ClientesPage` + `ClienteDetalleModal` + `RegistrarPagoClienteModal` + `ClienteFormModal`, **duplicados casi idénticos** en `apps/virikyna-gestion/src/pages/Clientes/` y `apps/virikyna-local/src/pages/Clientes/` (el diff es solo de imports y el manejo del error de red). El menú las llama "Cuentas corrientes" (`apps/virikyna-local/src/layout/AppShell.tsx:53`, `apps/virikyna-gestion/src/layout/AppShell.tsx:41`). En Gestión también se abre desde Caja Gestión → "Pendiente de cobro" (`apps/virikyna-gestion/src/pages/CajaGestion/PendienteCobroModal.tsx`).
- **Detalle:** es un modal de 680 px, no una pantalla (`ClienteDetalleModal.tsx:85-91`). Muestra saldo, tabla "Ventas a cuenta corriente" (fecha, N°, estado fiscal, total) y "Pagos recibidos". **No muestra saldo por venta, ni estado pagada/parcial, ni el detalle de la venta.**
- **Saldo:** vista `clientes_saldo` = `saldo_inicial + Σ ventas.total (cta. cte., no anuladas) − Σ pagos_cliente.monto` (dump:5238). No hay saldo por comprobante.
- **Cobro:** `RegistrarPagoClienteModal.tsx:51-56` → RPC `registrar_pago_cliente(cliente, venta|null, monto, forma)` (dump:3893). **Un solo medio**, sin fecha, sin nota, sin vista previa. Imputación: opcionalmente a **una** venta (`pagos_cliente.venta_id`), o "cuenta general". Cobros parciales: se aceptan, pero el sistema no sabe cuánto le queda a cada venta (no hay tabla de aplicaciones). No valida que el monto no supere el saldo.
- **Reversión:** existe vía Historial (`revertir_movimiento`, contra-asiento con `revierte_pago_cliente_id`, `docs/58_efectivo_local_no_impacta_gestion.sql:477-484`).
- **Devoluciones:** si se devuelve algo de una venta a cta. cte., `crear_devolucion` devuelve la diferencia en plata y **no** descuenta el saldo del cliente (dump:2271-2299; `clientes_saldo` no mira `devoluciones`). Hueco a cerrar; *a verificar en prueba real* qué hace hoy la UI de devolución en ese caso.

### 1.3 Clientes

- Tabla `clientes` (dump:5168): razón social / nombre fantasía (al menos uno), CUIT, domicilio, mail, celular, activo, saldo inicial, condición IVA. **No hay forma de distinguir externo de interno** ni **vínculo con `perfiles`/usuarios**. Hoy la única pista es el nombre.
- RLS `clientes_todos` (dump:7745): cualquier usuario activo lee y escribe directo (es una de las 4 tablas que las apps escriben sin RPC).
- Auditoría por trigger (`trg_auditoria_clientes`), borrado protegido si tiene historial (`fn_proteger_eliminacion_cliente`).

### 1.4 Ventas

- `ventas` (dump:5204): `subtotal`, `descuento_porcentaje` y `recargo_porcentaje` **globales**, `precio_oficial` (calculado), `precio_cobrado` (lo que confirma el cajero, puede redondear) y `total` (= `precio_cobrado`). `estado`: sin_facturar / facturado / anulada. `client_id` para idempotencia.
- `venta_items` (dump:5889): `cantidad`, `precio_unitario` (snapshot), **`descuento_porcentaje` por ítem (existe en la tabla pero Local siempre manda 0**, `apps/virikyna-local/src/pages/VentasPage.tsx:406-412`), `importe` (= cant × precio × (1 − desc. ítem); **no** incluye el descuento global), snapshot de nombre y marca. **No hay costo snapshot ni IVA por ítem.** Sin trigger de auditoría.
- **Los totales se guardan** (los calcula `confirmar_venta`, dump:2007-2145), no se recalculan al leer. El `precio_unitario` lo manda el front y el RPC no lo compara con `productos`.
- `venta_pagos`: una fila por medio, **no** se crea para cta. cte. (CHECK `chk_venta_pagos_no_cta_cte`).
- **No existe ninguna RPC para editar una venta.** Solo `anular_venta` (admin, solo sin Factura C, repone stock; dump:651-700). La RLS de `ventas` y `venta_items` es solo SELECT.

### 1.5 Fiscal

- La Factura C se emite **a mano** desde la pestaña Facturación (Local o Gestión), venta por venta; ninguna venta se factura sola. Una venta a cta. cte. hoy **puede** facturarse igual que cualquier otra: el listado no filtra por forma de pago (`apps/virikyna-gestion/src/pages/Facturacion/FacturacionTab.tsx:42-55`).
- El importe que va a ARCA es `ventas.total` (`supabase/functions/arca-emitir-factura/index.ts:276-278`).
- Reserva: `reservar_emision_factura_c` bloquea la venta (`FOR UPDATE`) y exige `estado = 'sin_facturar'` (dump:4417-4466). Al facturar pasa a `facturado`.
- **Una venta facturada no se puede anular ni editar** (decisión de Fase 1, `docs/06_estructura_de_datos.md:10` y :601). "Comprobante no fiscal" ya existe de hecho: es toda venta `sin_facturar` (el Comprobante X).

### 1.6 Stock

`confirmar_venta` registra `movimientos_stock` (tipo `venta`, ubicación `local`, `referencia_id` = venta) y actualiza `stock_ubicaciones` en la misma transacción, con la fecha de la venta (dump:2128-2140). Cambiar precios o descuentos de los ítems **no toca stock** mientras no se cambien cantidades ni productos. Anular sí repone.

### 1.7 Caja

- **Venta a cta. cte.:** no crea `venta_pagos` ni `movimientos_cuenta`; el Cierre la muestra aparte como `total_cuenta_corriente` (suma de `precio_cobrado`, dump:1899), informativo, no entra al efectivo esperado. El Cierre es un snapshot: si después cambia el total de la venta, el Z ya guardado **no** se actualiza.
- **Cobro de cliente:** `registrar_pago_cliente` inserta `movimientos_cuenta` en la cuenta mapeada (`cuenta_forma_pago`) siempre, sin origen; el Cierre de Local no lo cuenta (ver hallazgo 4).

### 1.8 Reportes y dashboards que leen importes de ventas

| Reporte | Fuente | Qué valor usa | ¿Cambia si se edita la venta? |
|---|---|---|---|
| Ventas por día (Gestión) | `dashboard_ventas_por_dia` (dump:2382) | `ventas.precio_cobrado` | Sí, retroactivo |
| Ventas semana (Local, admin) | `apps/virikyna-local/src/pages/Dashboard/queries.ts:11-23` | `precio_cobrado` | Sí |
| Top productos / Ventas por marca / Productos vendidos | `dashboard_ventas_por_producto` (dump:2408), `packages/shared/src/components/dashboard/ventasPorProducto.ts` | `venta_items.importe` prorrateado a `precio_cobrado` | Sí |
| Facturación / Ventas del día | `FacturacionTab`, `VentasDelDiaTab` | `ventas.*` + ítems | Sí (muestran lo nuevo) |
| Comprobante X impreso/PDF | `packages/shared/src/components/ComprobanteModal.tsx`, `lib/comprobanteLayout.ts` | `total` + ítems | Sí |
| Cierre X/Z | `cierres_caja` (snapshot) | `precio_cobrado` del momento | No |
| Saldo de cta. cte. | `clientes_saldo` | `ventas.total` | Sí (es lo buscado) |

**No existe hoy ningún reporte de margen de ventas ni libro de IVA.** "Margen por proveedor" (docs/13) es otra cosa: el markup al cargar facturas de compra.

### 1.9 Sincronización Local

No aplica PowerSync (hallazgo 1). Local usa React Query contra Supabase: verá la edición de Gestión al refrescar la consulta (cambio de pantalla, foco o invalidación). *A verificar en prueba real* el tiempo hasta verlo con la pantalla abierta (staleTime de las queries de clientes: hoy es `useState`+`useEffect`, sin React Query, recarga solo al abrir el modal).

### 1.10 Permisos

- Clientes / cuentas corrientes: **ambos roles, todo** (`docs/02_roles_y_permisos.md:41`; menú Local `roles: ['admin', 'cajero']`).
- RLS de `clientes`, `ventas`, `venta_items`, `pagos_cliente`: cualquier usuario activo lee **todo** (dump:7745, 7998, 8208, 8238).
- **Un cajero ve hoy la cuenta, las compras y el saldo de las dueñas y de sus compañeros**, y puede cobrarles y editarles la ficha. Y puede venderse a sí mismo con el descuento que quiera (caso venta 388).

---

## Parte 2 — Propuesta (no implementada)

### 2.1 Modelo de datos (cambios mínimos)

Principios que ya sigue el proyecto y se mantienen: escritura solo por RPC, policy de solo SELECT en tablas nuevas, contra-asiento en vez de borrar, auditoría por trigger, `SET search_path`, `WHERE` en todo UPDATE/DELETE (safeupdate), vistas con `security_invoker` (y re-declararlo en cada `CREATE OR REPLACE VIEW`).

```sql
-- docs/NN_cuentas_corrientes_clientes.sql — TENTATIVO, sin probar.
-- Agregar valores a un enum no se prueba con ROLLBACK: probar en la restauración local (:54329).

-- (a) Cliente interno y vínculo con el usuario
CREATE TYPE tipo_cliente AS ENUM ('externo', 'interno');
ALTER TABLE clientes
  ADD COLUMN tipo tipo_cliente NOT NULL DEFAULT 'externo',
  ADD COLUMN perfil_id uuid UNIQUE REFERENCES perfiles(id);  -- null = no es usuario del sistema
ALTER TABLE clientes ADD CONSTRAINT chk_cliente_interno_perfil
  CHECK (perfil_id IS NULL OR tipo = 'interno');
-- Carga inicial: los 5 actuales → 'interno' + su perfil_id (Alicia, Ana Julia, Ale, Jose, Belu).

-- (b) Estado del comprobante interno (separado del estado fiscal)
CREATE TYPE estado_cuenta_interna AS ENUM ('pendiente', 'finalizado');
ALTER TABLE ventas
  ADD COLUMN estado_interno estado_cuenta_interna,          -- null = no es venta interna
  ADD COLUMN total_original numeric(12,2),                  -- lo que registró el cajero (precio_cobrado al vender)
  ADD COLUMN finalizada_at timestamptz,
  ADD COLUMN finalizada_por uuid REFERENCES perfiles(id);
-- Se completa en confirmar_venta: cliente interno + forma 'cuenta_corriente' → estado_interno='pendiente',
-- total_original = precio_cobrado. Se bloquea emitir Factura C mientras estado_interno IS NOT NULL
-- (ver decisión D5).

-- (c) Precio original vs final por ítem
ALTER TABLE venta_items
  ADD COLUMN precio_unitario_original numeric(12,2),        -- null = nunca se editó
  ADD COLUMN costo_unitario numeric(12,2);                  -- snapshot del costo al vender (de acá en más)
-- venta_items.descuento_porcentaje ya existe: es el % individual. importe se recalcula con él.
-- + trigger fn_auditoria_generica en venta_items (hoy no tiene).

-- (d) Imputación de cobros a comprobantes (espejo de pagos_proveedor_aplicaciones)
CREATE TABLE pagos_cliente_aplicaciones (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pago_cliente_id uuid NOT NULL REFERENCES pagos_cliente(id),
  venta_id uuid NOT NULL REFERENCES ventas(id),
  monto numeric(12,2) NOT NULL CHECK (monto > 0),
  operacion_id uuid NOT NULL,
  usuario_id uuid NOT NULL REFERENCES perfiles(id),
  revertida_at timestamptz, revertida_por uuid REFERENCES perfiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
-- Varios medios por cobro (espejo de pagos_proveedor_medios)
CREATE TABLE pagos_cliente_medios (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pago_cliente_id uuid NOT NULL REFERENCES pagos_cliente(id),
  forma_pago forma_pago_venta NOT NULL CHECK (forma_pago NOT IN ('cuenta_corriente','combinado')),
  monto numeric(12,2) NOT NULL CHECK (monto <> 0),
  orden int NOT NULL,
  -- si se aceptan cheques de clientes (decisión D3): numero, banco, fecha_pago, propio=false
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE pagos_cliente
  ADD COLUMN origen origen_egreso NOT NULL DEFAULT 'general',  -- 'turno' = cobrado en la caja de Local
  ADD COLUMN fecha date NOT NULL DEFAULT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
  ADD COLUMN nota text;
-- pagos_cliente.venta_id queda DEPRECATED (igual que pagos_proveedor.factura_compra_id en docs/31).

-- (e) Vista de saldo por comprobante (espejo de facturas_compra_saldo)
CREATE VIEW ventas_cuenta_corriente_saldo WITH (security_invoker = on) AS
SELECT v.id, v.numero, v.cliente_id, v.created_at, v.total, v.total_original,
       v.estado, v.estado_interno, x.aplicado AS total_aplicado,
       v.total - x.aplicado - x.devuelto AS saldo_pendiente,
       CASE WHEN v.estado_interno = 'pendiente' THEN 'a_revisar'
            WHEN v.estado_interno = 'finalizado' THEN 'finalizado'
            WHEN v.total - x.aplicado - x.devuelto <= 0 THEN 'pagada'
            WHEN x.aplicado > 0 THEN 'parcial' ELSE 'pendiente' END AS estado_cuenta
FROM ventas v
CROSS JOIN LATERAL (
  SELECT COALESCE((SELECT sum(a.monto) FROM pagos_cliente_aplicaciones a
                   WHERE a.venta_id = v.id AND a.revertida_at IS NULL), 0) AS aplicado,
         0::numeric AS devuelto  -- a definir: devoluciones activas sobre esta venta (hueco 1.2)
) x
WHERE v.forma_pago = 'cuenta_corriente' AND v.estado <> 'anulada';
-- clientes_saldo se recalcula: saldo_inicial + Σ ventas (excluye internas finalizadas) − Σ pagos.
```

RPCs nuevas (todas `SECURITY DEFINER`, validan rol, auditan):

- `registrar_cobro_cliente(p_cliente_id, p_medios jsonb, p_venta_ids uuid[], p_origen, p_fecha, p_nota, p_monto)` — espejo de `registrar_pago_proveedor_v3`. Con `origen='turno'` y efectivo **no** crea `movimientos_cuenta` (regla docs/58) y `cerrar_caja` lo suma al efectivo esperado; con `origen='general'` impacta la cuenta mapeada. Reemplaza a `registrar_pago_cliente` (se deja la vieja sin usar).
- `aplicar_cobros_a_cuenta` / `desaplicar_cobro` — espejo de docs/52.
- `editar_venta_interna(p_venta_id, p_items jsonb /* [{item_id, descuento_porcentaje}] */)` — solo admin, solo `estado_interno='pendiente'`, `estado='sin_facturar'`, sin cobros aplicados. Bloquea la venta (`FOR UPDATE`), guarda `precio_unitario_original` la primera vez, recalcula `importe`, `subtotal`, `precio_oficial`, `precio_cobrado`, `total`. **No toca** cantidades, productos, `movimientos_stock` ni `created_at`. El descuento global de la cabecera: ver decisión D6.
- `finalizar_venta_interna(p_venta_id)` — solo admin: `estado_interno='finalizado'`, `finalizada_at/por`. Sin `movimientos_cuenta`, sin `venta_pagos`.
- `reabrir_venta_interna` — opcional (decisión D7).
- `confirmar_venta` — dos agregados: marcar la venta interna y guardar `costo_unitario` desde `productos.costo`.

### 2.2 Reutilización (sin duplicar)

1. **Generalizar la pantalla, no copiarla.** Extraer de `ProveedorCuentaCorriente` un esqueleto compartido (`CuentaCorrienteLayout`): cabecera con volver + título + acción principal, fila de KPIs (`Kpi` ya es genérico), tabs accesibles, barra de filtros, tabla con selección y barra sticky, tabla de movimientos. Las columnas, filtros, acciones por fila y KPIs entran por props/render-props, como ya se hace con `renderDetalle`. `ProveedorCuentaCorriente` pasa a usar el esqueleto (sin cambio visible) y nace `ClienteCuentaCorriente`.
2. **Selección y reparto:** generalizar `simularRepartoPago` a "comprobantes con saldo + créditos opcionales" (para clientes no hay NC de compra; el crédito sería la devolución) y reusar `ResultadoReparto` y la tabla "Cómo se reparte".
3. **Medios:** `MediosPagoEditor` hoy tipa `FormaPagoEgreso` y piensa en cheques propios. Parametrizarlo por lista de medios + etiquetas + "¿lleva datos de cheque?". La aritmética de `mediosPago.ts` ya es genérica.
4. **Una pantalla para Local y Gestión** en `packages/shared`, con props (`origen`, `permitirEditarInterno`, `permitirFinalizar`) como hace proveedores. De paso se eliminan los 4 archivos de clientes duplicados en cada app.
5. **Ruta** `/clientes/:id` en ambas apps (hoy es modal), igual que `/proveedores/:id`.

### 2.3 Cierre sin cobro (internas)

- "Finalizado" no es "pagado": el comprobante interno finalizado sale del saldo pendiente por estado, **sin** `pagos_cliente`, **sin** `movimientos_cuenta`, **sin** `venta_pagos`. Así ni Caja Gestión, ni el Z, ni los saldos de cuentas se mueven.
- `clientes_saldo` excluye las internas finalizadas → la deuda "pendiente de cobro" de Caja Gestión (`ResumenCuentasTab.tsx:28`) no muestra plata que nunca va a entrar.
- En la UI: badge "Finalizado — se descuenta del sueldo" (texto a validar) y la cuenta del empleado muestra lo acumulado por mes como dato informativo (el sistema no calcula ni registra sueldos).

### 2.4 Reportes: original vs. final

| Reporte | Propuesta | Por qué |
|---|---|---|
| Ventas por día / semana, Top productos, por marca | **Final** | Es lo que efectivamente se "vendió" (el descuento es real). Requiere aceptar que el número de un día pasado cambie cuando la dueña edita. |
| Cierre X/Z | **Original** (snapshot, no cambia) | No tiene efectivo en juego: la cta. cte. es informativa. Mostrar el número cerrado. |
| Comprobante X impreso | **Final** al finalizar; el original queda en el historial | El empleado tiene que ver lo que se le descuenta. |
| Saldo de cuenta | **Final** | |
| Factura C | No aplica a internas (D5). Para externas, nada cambia: no se editan. | |
| Futuro reporte de margen | Final contra `costo_unitario` | |

Alternativa (decisión D8): excluir las ventas internas de los dashboards de ventas, o mostrarlas aparte ("consumo interno"), porque un 30-50 % de descuento a empleados distorsiona el ticket promedio y el ranking.

### 2.5 Margen en el modal

- **De acá en adelante:** `venta_items.costo_unitario` snapshot al vender (agregado en `confirmar_venta`). Es lo correcto: el margen no cambia si después sube el costo.
- **Ventas ya hechas (hoy solo la N° 388):** usar `productos.costo` actual, rotulado "costo actual".
- **Unidades:** `productos.costo` es **sin IVA** (precio = costo × (1+m1) × (1+m2) × (1+IVA), `docs/06_estructura_de_datos.md:192-194`). Virikyna es monotributista: el IVA de compra es costo. Para comparar con el precio de venta (que lo incluye) el modal tiene que usar **costo × (1 + IVA)**. *A verificar con la clienta* qué "costo" espera ver.
- **Productos con precio manual** (`precio_manual`, costo vacío): sin margen → mostrar "sin costo cargado", no 0 %.
- **Qué mostrar por fila:** costo unitario, precio registrado, % desc. (input), precio final (en vivo), margen en $ y en % sobre el final, en rojo si queda **por debajo del costo**. Total original, total final, ahorro.

### 2.6 Riesgos

| Riesgo | Mitigación |
|---|---|
| **Factura C sobre una venta interna** (y después ya no se puede editar ni anular) | Bloquear en `reservar_emision_factura_c` y ocultar del listado de Facturación mientras sea interna. Probar con la reserva interceptada; **nunca emitir una Factura C real para probar**. |
| Ediciones concurrentes (dos admins, o editar mientras se factura) | `FOR UPDATE` sobre la venta en la RPC + chequear una `version`/`updated_at` que manda el modal; si cambió, recargar. |
| Editar después de cobrar parte | Bloquear edición si hay aplicaciones vigentes. |
| Cajero se vende a sí mismo con descuento (pasó) | En `confirmar_venta`, para clientes internos: rechazar descuento/recargo/redondeo del cajero (o permitirlo y que la dueña lo vea). Mostrar quién cargó vs. quién compró. Decisión D2. |
| Privacidad entre empleados | Ver D4. Cambiar RLS de `ventas`/`venta_items`/`pagos_cliente` es delicado: Facturación y Ventas del día leen todas las ventas. Lo más seguro es filtrar en una vista/RPC de cuenta corriente y no tocar la RLS de `ventas`. |
| Cobros en efectivo en Local mal contados (hallazgo 4) | Resolverlo en la fase 1 junto con el origen. Hoy 0 cobros: no hay datos que migrar. |
| Devolución sobre venta a cta. cte. no baja el saldo | Definir la regla (crédito en cuenta vs. plata) antes de la fase 2. |
| Reportes que cambian hacia atrás | Comunicarlo; o D8. |
| Datos existentes | 5 clientes a marcar como internos + vincular perfil; venta 388 a decidir (D9); `pagos_cliente` vacío. Re-verificar en prod justo antes de migrar (Alicia edita a mano). |
| Local viejo instalado | La UI nueva de Local requiere release; la base debe seguir aceptando el Local anterior (RPC nuevas, sin romper `registrar_pago_cliente` ni `confirmar_venta` actuales). |

### 2.7 Orden de fases sugerido

1. **Datos y RPCs** — migración (tipo de cliente, perfil, estado interno, costo snapshot, aplicaciones, medios, origen), vistas, `registrar_cobro_cliente`, ajuste de `cerrar_caja`, bloqueo de Factura C para internas, `confirmar_venta` con costo y marca interna. Probada en la restauración local. Backup etiquetado antes de aplicar.
2. **Cobros a clientes externos** — esqueleto compartido de cuenta corriente, `ClienteCuentaCorriente` en `/clientes/:id` (Gestión y Local), selección múltiple, varios medios, parciales, historial. Proveedores migra al esqueleto sin cambios visibles.
3. **Internos en Gestión** — marcar clientes internos en la ficha; modal de edición del comprobante con % por ítem y margen; Finalizar; bloqueo en Facturación.
4. **Vista en Local** — detalle de cuenta interna con comprobante final y estado; reglas de qué ve cada cajero; release de Local (3 archivos de versión + tag + CHANGELOG, que además tiene pendiente lo de docs/62).

---

## Parte 3 — Decisiones para validar con la clienta

| # | Pregunta | Por qué importa |
|---|---|---|
| D1 | ¿Las dueñas (Alicia, Ana Julia) también llevan cuenta interna, o solo los empleados? Si las dueñas: ¿se "finaliza" igual (sin cobro) o es retiro de mercadería? | Hoy están cargadas como clientas. |
| D2 | ¿El cajero puede aplicar descuento/redondeo cuando vende a un interno, o siempre registra precio de lista y descuenta solo la dueña? ¿Puede un empleado venderse a sí mismo? | Caso real: venta 388, Ale se cargó 30 %. |
| D3 | Clientes externos: ¿qué medios de cobro? ¿Reciben cheques/eCheq de clientes? (hoy el sistema solo maneja cheques propios). ¿Cuántos medios combinados por cobro? | Define `pagos_cliente_medios` y si hay cartera de cheques recibidos. |
| D4 | En Local, ¿cada cajero ve solo su cuenta, o todas? ¿Un cajero puede cobrarle a otro? ¿Las cuentas de las dueñas se ven en Local? | Hoy cualquiera ve todo. |
| D5 | ¿Una venta interna puede llevar Factura C alguna vez? (propuesta: no) | Facturada ya no se edita ni anula. |
| D6 | Si la venta ya trae un descuento global, ¿la dueña lo reemplaza por los % por ítem o se suman? | Fórmula del total final. |
| D7 | Una vez finalizado, ¿se puede reabrir para corregir? ¿Quién? | RPC de reapertura y auditoría. |
| D8 | ¿Las ventas internas cuentan en los dashboards de ventas, o van aparte como "consumo interno"? | Distorsiona ticket promedio y ranking. |
| D9 | ¿Qué se hace con la venta N° 388 (Ale, $25.900 con 30 %)? ¿Se edita con el flujo nuevo, se deja como está, se finaliza? | Único dato existente. |
| D10 | ¿Qué costo quiere ver la dueña en el margen: con IVA de compra o sin? ¿Margen sobre precio final o sobre costo (markup)? | Unidades del modal. |
| D11 | ¿Hace falta ver un total por mes por empleado (para descontar del sueldo)? ¿Corte por fecha de venta o de finalización? | Vista de estado de cuenta. |
| D12 | Devoluciones de una venta a cta. cte.: ¿baja la deuda o se devuelve plata? | Hueco actual de `clientes_saldo`. |
| D13 | Cobros desde Local: ¿se siguen haciendo en la caja (entran al Z) o solo desde Gestión? | Regla de efectivo de docs/58. |

---

## A verificar en prueba real

- Cuánto tarda Local en mostrar una edición hecha en Gestión con la pantalla abierta.
- Qué hace hoy la UI de devolución de Local con una venta a cta. cte.
- Que una venta a cta. cte. hoy pueda emitirse como Factura C desde Facturación (por código sí; confirmar en pantalla, **sin emitir**: interceptar `reservar_emision_factura_c`).
- Que un cobro en efectivo en Local no aparece en el efectivo esperado del Cierre X (probar con SQL y ROLLBACK, o en la restauración local).
- Comportamiento del modal de margen en pantallas de la caja (resolución real) y tamaños de inputs numéricos según docs/08 §5.1.
