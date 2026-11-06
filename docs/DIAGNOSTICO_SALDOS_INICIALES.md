# Diagnóstico: saldos iniciales de cuentas corrientes

Fecha: 2026-11-05 · Alcance: Virikyna Gestión · **Solo diagnóstico, sin cambios en código, schema ni datos.**

Fuentes: código del repo (rama `lote-oct-2026`), definiciones vigentes del backup `backups/virikyna_2026-11-05_0753/schema.sql` (el `supabase/schema/schema.sql` del repo está desactualizado) y consultas de solo lectura a producción del 2026-11-05.

---

## Respuesta corta para la dueña

- **Cargar dos veces no suma.** Para proveedores y clientes, la segunda carga sobre el mismo proveedor o cliente **se rechaza con un error y no se guarda nada** (tampoco el resto de lo que se cargó en esa pantalla). Para las cuentas de dinero (Efectivo, etc.) la base no permite una segunda carga.
- **Hoy hay 3 saldos iniciales cargados, todos de proveedores, uno por proveedor, cargados por Alicia.** Ninguna cuenta de dinero y ningún cliente tiene saldo inicial.

| Proveedor | Saldo inicial | Cargado | Usuario | Cargas |
|---|---:|---|---|---:|
| GUTIERREZ LEANDRO - LIBROS | $ 1.972.962,10 | 20/10/2026 09:32 | Alicia | 1 |
| THE TOY COMPANY S.R.L. - TOYCO (LEO BIOSCA) | $ 1.120.280,00 | 20/10/2026 09:34 | Alicia | 1 |
| LUX ATLANTIC S.A. (FERNANDEZ) | $ 439.146,66 | 03/11/2026 11:45 | Alicia | 1 |

Ninguna cuenta tiene más de una carga.

---

## 1. Cómo se guarda hoy

Hay **dos mecanismos distintos**, y los dos se cargan desde la misma pantalla.

**Pantalla:** Caja Gestión → pestaña "Carga inicial" ([CargaInicialTab.tsx](../apps/virikyna-gestion/src/pages/CajaGestion/CargaInicialTab.tsx)). Envía todo junto al RPC `cargar_saldos_iniciales(p_saldos_cuentas, p_saldos_proveedores, p_saldos_clientes)` ([CargaInicialTab.tsx:84](../apps/virikyna-gestion/src/pages/CajaGestion/CargaInicialTab.tsx#L84); definición en el backup `schema.sql:1818-1851`, también en [docs/06](06_estructura_de_datos.md) ~L1110). El RPC es `SECURITY DEFINER` y exige rol admin activo. Solo existe en Gestión: Local tiene la etiqueta, pero no tiene la pantalla.

| Tipo de cuenta | Dónde se guarda | ¿Es un campo o un movimiento? |
|---|---|---|
| **Cuentas de dinero** (`cuentas`: Efectivo, MP, banco…) | `movimientos_cuenta` con `tipo = 'saldo_inicial'`, `monto`, `descripcion = 'Carga inicial del sistema'`, `usuario_id`, `created_at` | **Movimiento.** Suma al saldo de la vista `cuentas_saldo` |
| **Proveedores** | `proveedores.saldo_inicial NUMERIC(12,2) DEFAULT 0` | **Campo** de la ficha. No es un comprobante ni un movimiento |
| **Clientes**, incluidas las cuentas internas (dueñas y empleados son filas de `clientes`; ver [DIAGNOSTICO_CUENTAS_CORRIENTES.md](DIAGNOSTICO_CUENTAS_CORRIENTES.md)) | `clientes.saldo_inicial NUMERIC(12,2) DEFAULT 0` | **Campo** de la ficha |

Cómo entra al saldo:
- Proveedor: vista `proveedores_saldo` → `saldo_actual = saldo_inicial + facturado − pagado` (`schema.sql:5836-5838`).
- Cliente: vista `clientes_saldo` → `saldo_actual = saldo_inicial + ventas a cta. cte. − pagos` (`schema.sql:5247-5249`).

Los clientes internos y los externos usan exactamente el mismo mecanismo, porque la base no los distingue.

Los formularios de alta y edición de proveedor y de cliente **no** leen ni escriben `saldo_inicial` ([ProveedorFormModal.tsx:50-61](../apps/virikyna-gestion/src/pages/Proveedores/ProveedorFormModal.tsx#L50-L61), [ClienteFormModal.tsx:60-68](../apps/virikyna-gestion/src/pages/Clientes/ClienteFormModal.tsx#L60-L68)). [AUDITORIA_FUNCIONALIDADES.md](AUDITORIA_FUNCIONALIDADES.md) dice que el ABM incluye el saldo inicial, y eso es inexacto.

## 2. Qué pasa si se carga dos veces

| Tipo | Comportamiento | Restricción |
|---|---|---|
| Proveedor / cliente | El RPC lee el valor actual. Si es distinto de 0, hace `RAISE EXCEPTION 'El proveedor <uuid> ya tiene un saldo inicial cargado (<monto>)…'`. Si es 0, hace `UPDATE … SET saldo_inicial = monto`, es decir, **reemplaza un 0** | Validación dentro del RPC. No hay constraint en la tabla |
| Cuenta de dinero | Inserta un movimiento nuevo. Un segundo intento choca con el índice único | `ux_movimientos_cuenta_saldo_inicial_por_cuenta` (UNIQUE `cuenta_id` WHERE `tipo='saldo_inicial'`, `schema.sql:6602`) |

En ningún caso suma. Todo el envío corre en una sola transacción: si un proveedor ya tenía saldo, **se descarta toda la carga de esa vez**, también lo que estaba bien.

**Bloqueo de la pantalla.** La UI considera la carga "ya hecha" solo si existe algún movimiento `saldo_inicial` en **cuentas de dinero** ([CargaInicialTab.tsx:32](../apps/virikyna-gestion/src/pages/CajaGestion/CargaInicialTab.tsx#L32), [:100-104](../apps/virikyna-gestion/src/pages/CajaGestion/CargaInicialTab.tsx#L100-L104)). Hoy hay 0 movimientos de ese tipo, así que **la pantalla sigue abierta y editable**. Por eso Alicia pudo cargar en dos fechas distintas (20/10 y 03/11). Además, el formulario muestra todos los inputs vacíos y no indica qué proveedor ya tiene saldo. Por eso no se acuerda de en cuáles cargó.

## 3. Datos actuales (consulta de solo lectura, 2026-11-05)

Controles:

| | Total | Con saldo inicial ≠ 0 | Suma |
|---|---:|---:|---:|
| Cuentas de dinero | 3 | 0 movimientos `saldo_inicial` | — |
| Proveedores | 25 | 3 | $ 3.532.388,76 |
| Clientes (incluye internos) | 6 | 0 | $ 0 |

Detalle: ver la tabla del principio. Datos que salen de la auditoría:
- Las 3 cargas son ediciones de la ficha en las que **solo cambió `saldo_inicial`** (de 0 al monto), así que vienen de la pantalla de Carga inicial.
- No hay saldos iniciales sin rastro en la auditoría. La auditoría de proveedores y clientes empieza el 14/10/2026.
- Ninguno de los 3 proveedores tiene facturas de compra cargadas, ni antes ni después de la carga. Toda su deuda es el saldo inicial, y no hay riesgo de que el monto se haya contado dos veces junto con facturas.
- Los 3 ya están cancelados con pagos:

| Proveedor | Saldo inicial | Pagado | Saldo actual |
|---|---:|---:|---:|
| GUTIERREZ | 1.972.962,10 | 1.972.962,10 (28/10, con un pago revertido en el medio) | 0,00 |
| TOYCO | 1.120.280,00 | 1.120.280,00 (02/11, con un pago revertido en el medio) | 0,00 |
| LUX ATLANTIC | 439.146,66 | 439.146,68 (03/11) | **−0,02 (a favor)** |

## 4. Dónde se ve hoy

| Lugar | ¿Muestra el saldo inicial? |
|---|---|
| Caja Gestión → Carga inicial | Solo en modo "ya realizada", que hoy no se activa (ver punto 2). En modo carga muestra inputs vacíos y no el valor guardado |
| Cta. cte. de proveedor ([ProveedorCuentaCorriente.tsx:355-374](../packages/shared/src/components/ProveedorCuentaCorriente.tsx#L355-L374)) | **No.** Muestra Saldo, Comprobantes pendientes, Crédito NC, "A cuenta (pagos) — sin comprobante" y Último pago. El saldo inicial queda adentro de "Saldo" y no aparece en el listado de comprobantes |
| Detalle de cliente ([ClienteDetalleModal.tsx:97](../apps/virikyna-gestion/src/pages/Clientes/ClienteDetalleModal.tsx#L97)) | **No.** Solo el saldo total, las ventas a cta. cte. y los pagos |
| Listados de proveedores y clientes, Resumen de cuentas | Solo el `saldo_actual` total |
| Movimientos de cuenta (Caja Gestión) | Sí: tipo "Carga inicial" ([caja.ts:31](../apps/virikyna-gestion/src/lib/caja.ts#L31)). Solo aplica a cuentas de dinero, que hoy no tienen ninguno |

Como no es un comprobante, el saldo inicial **no se confunde con una factura, pero tampoco se ve en ningún lado**. El efecto concreto en los 3 proveedores: la cta. cte. muestra Saldo $0 y, en verde, "A cuenta (pagos) $1.972.962,10 — sin comprobante". Los pagos que cancelaron el saldo inicial aparecen como un crédito a favor sin aplicar, aunque en realidad están compensados.

## 5. Trazabilidad

- **Cuentas de dinero:** el movimiento guarda `usuario_id` y `created_at`, y el trigger `trg_auditoria_movimientos_cuenta` lo registra en `auditoria` (solo INSERT). Se corrige con contra-asiento (`revierte_movimiento_id`).
- **Proveedores y clientes:** el campo no guarda fecha ni usuario. La trazabilidad sale **solo de la tabla `auditoria`**, a través de los triggers genéricos `trg_auditoria_proveedores` y `trg_auditoria_clientes` (INSERT, UPDATE y DELETE, con la fila completa antes y después y `auth.uid()`). La auditoría solo la puede leer un admin, y no hay ninguna pantalla que muestre el historial del saldo inicial.
- Los intentos rechazados (segunda carga) **no dejan rastro**, porque la transacción se revierte.

## Riesgos

1. **La pantalla "de uso único" no se bloquea.** El bloqueo depende de que exista un saldo inicial de cuenta de dinero, y no hay ninguno. Cualquier admin puede volver a usarla, y además no muestra lo ya cargado. Eso es justamente lo que generó la duda de la dueña.
2. **Error confuso ante una carga repetida.** El mensaje muestra el UUID del proveedor o cliente, no el nombre, y descarta **todo** el envío. Alguien que carga 20 proveedores y repite uno pierde los 20.
3. **No hay forma de corregir desde la app.** El mensaje dice "corregilo por separado", pero ninguna pantalla edita `saldo_inicial`. La única vía es un UPDATE directo. Por RLS, `proveedores_update` y `clientes_todos` dejan que **cualquier usuario activo** (no solo admin) cambie `saldo_inicial` vía API. Ningún trigger lo protege, a diferencia de los márgenes (`fn_proteger_margen_proveedor`). Queda auditado, salvo que se use `virikyna.suppress_audit`.
4. **El saldo inicial no se ve, y los pagos que lo cancelan aparecen como "a cuenta".** En los 3 proveedores, el KPI "A cuenta (pagos)" muestra más de $3,5 M como saldo a favor sin aplicar. Si alguien intenta aplicar esos pagos "a cuenta" a facturas futuras (docs/52), descontaría deuda que ya estaba pagada.
5. **LUX ATLANTIC con −$0,02 a favor.** Es una diferencia de redondeo entre el saldo inicial y el pago.
6. **Efectivo y las demás cuentas de dinero no tienen saldo inicial.** [docs/58](58_efectivo_local_no_impacta_gestion.sql) (L34) ya anotaba que al Efectivo de Gestión "le falta el saldo inicial". Si la dueña cree que lo cargó, no fue así.
7. **El monto no tiene fecha de referencia.** No hay una "fecha de corte" del saldo inicial. Solo existe la fecha de carga, que está en la auditoría.
