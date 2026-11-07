# Diagnóstico: ajuste por redondeo en comprobantes, pagos y cobros

Fecha: 2026-11-07 · Alcance: Virikyna Local, Gestión e Inventario · **Solo diagnóstico, sin cambios en código, schema ni datos.**

> **Implementado el 2026-11-07** con D1–D6 aprobadas tal como están abajo: `docs/71_ajuste_redondeo.sql` (aplicada en producción) y `docs/06_estructura_de_datos.md` §39. Además del plan, el ajuste quedó también en el pago desde el detalle de una factura (Local y Gestión), y la pantalla calcula cada línea con el mismo redondeo que la base.

Fuentes: código del repo (rama `lote-oct-2026`), `supabase/schema/schema.sql` (regenerado con docs/70, vigente) y consultas de solo lectura a producción del 2026-11-07.

Pedido de la dueña: poder cargar un **ajuste por redondeo** (centavos) que sume o reste **sobre el total final, fuera del IVA**, en todos los comprobantes que manejan importes. **Sin tope.** Lo pueden usar **admin y cajeros**. Se hacen las dos partes juntas: en comprobantes de compra (parte A) y en pagos y cobros de cuenta corriente (parte B).

---

## Respuesta corta para la dueña

- **Hoy no se puede.** Si en un ítem se escribe un importe con `-`, el campo lo rechaza ("No puede ser negativo") y la factura no se guarda. No hay ningún otro lugar para cargar un ajuste.
- **Se puede agregar sin tocar el IVA ni los costos.** El ajuste va como un renglón propio del pie de totales ("Ajuste por redondeo"), debajo del IVA, y suma o resta al total. Los ítems, el IVA, el costo de los productos y el stock quedan igual.
- **En pagos y cobros** se agrega el mismo renglón: cuando la plata que entra o sale difiere del saldo por centavos, el ajuste cierra la diferencia sin mover la caja.
- **Ventas del local: no hace falta.** Ya existe: el cajero cobra un precio redondeado y el ticket imprime "Diferencia (redondeo)".
- **Hoy no hay centavos colgados en producción.** LUX ATLANTIC (−0,02) quedó en 0 el 06/11, cuando se corrigió su saldo inicial.

---

## 1. Qué hay hoy

### 1.1 Comprobantes de compra (facturas, NC, ND, remitos, cupones, presupuestos)

| Dónde | Qué hace |
|---|---|
| Fila de ítem, artículos y servicios ([ItemFacturaRow.tsx:163](../packages/shared/src/components/ItemFacturaRow.tsx#L163), [:280](../packages/shared/src/components/ItemFacturaRow.tsx#L280)) | El importe es un `MontoInput` sin la prop `negativo`: un `-` da error y la factura no se guarda ([MontoInput.tsx:27](../packages/shared/src/components/MontoInput.tsx#L27)) |
| Totales en pantalla ([totalesCompra.ts:56-73](../packages/shared/lib/totalesCompra.ts#L56-L73)) | `total = subtotal sin IVA + IVA`. No hay otro término |
| RPC `cargar_factura_compra` (`schema.sql:1561`) | `v_total := v_total_sin_iva + v_iva`. **No valida signos**: suma lo que llegue en `precio_unitario_sin_iva`. La traba es solo de la pantalla |
| RPC `cargar_factura_compra_contado` (`schema.sql:1780`) | Paga el total que calculó el servidor; exige total > 0 |
| RPC `editar_factura_compra` (`schema.sql:2915`) | Si cambia la alícuota recalcula `total = total_sin_iva + IVA` (L2973). Con un ajuste, **lo borraría** |
| Tabla `facturas_compra` (`schema.sql:6649`) | `total_sin_iva`, `iva`, `total`. Sin columna de ajuste. Hoy `total = total_sin_iva + iva` en las 28 facturas vigentes |
| Vista `facturas_compra_saldo` (`schema.sql:6726`) | `saldo_pendiente = total − aplicado`. El saldo del proveedor (`proveedores_saldo`, `schema.sql:7031`) también sale de `total` |

Como el saldo del proveedor y el de cada factura salen de `total`, **un ajuste que entre en `total` impacta solo en la cuenta corriente**, sin tocar las vistas de saldo.

**Por qué no sirve habilitar el `-` en los ítems:**
- En artículos, un ítem con producto vinculado y precio negativo le pondría **costo negativo** al producto y le recalcularía el precio de venta (`cargar_factura_compra`, L1736-1763).
- El ítem queda **dentro del IVA**: un −0,02 sin IVA da −0,0242 en el total, y el redondeo no cierra.
- Un `-` tipeado sin querer en un ítem común pasaría sin aviso.

### 1.2 Pagos a proveedores y cobros a clientes

| | Pagos a proveedores | Cobros a clientes |
|---|---|---|
| RPC | `registrar_pago_proveedor_v3` (`schema.sql:4930`); v2 y el contado delegan en v3 | `registrar_cobro_cliente` (`schema.sql:4466`) |
| Monto | Suma de los medios (plata real) | Suma de los medios |
| Qué cancela | Reparte el monto entre comprobantes, más viejos primero; lo que sobra queda **a cuenta** | Igual, contra ventas a cta. cte.; no deja cobrar más que `saldo_cobrable` |
| Caja | Un egreso por medio y movimientos de cuenta según origen | Cierre de Local suma `pagos_cliente_medios` con JOIN (`schema.sql:2031-2039`); Gestión mueve cuentas por medio |
| Saldo | `proveedores_saldo.total_pagado = Σ pagos_proveedor.monto` | `clientes_saldo.total_pagado = Σ pagos_cliente.monto` |
| A cuenta | `pagos_proveedor_a_cuenta`: `monto − aplicado`, vigente si `monto > 0` | `pagos_cliente_a_cuenta`: igual |
| Reversión | `revertir_movimiento` copia el pago en negativo (`schema.sql:5584`) | Igual (`schema.sql:5656`) |

El problema de centavos aparece **al pagar o cobrar**. Si una factura de $ 10.000,02 se paga con $ 10.000, quedan 0,02 pendientes para siempre. Si se paga con $ 10.000,05, quedan 0,03 "a cuenta". Hoy la única salida es revertir el pago y cargarlo de nuevo con el importe exacto.

### 1.3 Lo que ya está resuelto o no se toca

| Dónde | Estado |
|---|---|
| Ventas del local | Ya tienen redondeo: `ventas.precio_oficial` vs `precio_cobrado`, y el ticket imprime "Diferencia (redondeo)" ([comprobanteLayout.ts:122](../packages/shared/lib/comprobanteLayout.ts#L122)) |
| Factura C (ARCA) | Toma el total de la venta, que ya viene redondeado. No se toca: lo que se informa tiene que cerrar exacto y no se puede probar sin emitir |
| Saldos iniciales | Se corrigen con `corregir_saldo_inicial` (docs/69) |
| Caja, cierres, egresos | Registran la plata real. Una diferencia de centavos en caja tiene que verse (sobrante o faltante), no taparse |

## 2. Datos actuales (solo lectura, 2026-11-07)

| Control | Resultado |
|---|---:|
| Facturas de compra vigentes | 28 (6 de contado) |
| Pagos a proveedores / cobros a clientes | 24 / 0 |
| Ventas a cta. cte. | 2 |
| Facturas con `total ≠ total_sin_iva + iva` | 0 |
| Facturas con `total_sin_iva ≠ Σ ítems` | 0 |
| Facturas, NC, pagos, ventas o cobros con residuo entre 0 y $ 100 | **0** |
| Proveedores o clientes con saldo entre 0 y $ 100 | **0** (LUX ATLANTIC: saldo 0, saldo inicial corregido a 439.146,68 el 06/11) |

No hay nada que corregir hacia atrás. El ajuste es para lo que se cargue de acá en adelante.

## 3. Propuesta

Una sola idea en todos lados: **el ajuste es un importe con signo, aparte, que se suma al final.** No es un ítem ni un medio de pago, y nunca mueve stock, costo, IVA ni caja.

### Parte A: ajuste en comprobantes de compra

**Base**
- `facturas_compra.ajuste_redondeo NUMERIC(12,2) NOT NULL DEFAULT 0`.
- Regla: `total = total_sin_iva + iva + ajuste_redondeo`, con un CHECK en la tabla que la hace cumplir. Las 28 facturas actuales ya la cumplen con ajuste 0.
- `cargar_factura_compra` y `cargar_factura_compra_contado` reciben `p_ajuste_redondeo NUMERIC DEFAULT 0`. Con el default, las apps viejas siguen funcionando igual. Al agregar el parámetro cambia la firma: hay que hacer `DROP FUNCTION` de la vieja y crear la nueva, porque `CREATE OR REPLACE` dejaría dos versiones y PostgREST no sabría a cuál llamar. Hay que volver a dar los GRANT.
- **Validación (no es un tope):** el total no puede quedar negativo. El contado ya exige total > 0.
- `editar_factura_compra`: al recalcular por cambio de alícuota conserva el ajuste. Suma `p_ajuste_redondeo` para corregirlo, con la misma regla que el IVA: **solo admin y solo si el comprobante no tiene pagos ni NC aplicados**.
- `facturas_compra_saldo`: se agrega la columna `ajuste_redondeo` al final, con `CREATE OR REPLACE VIEW … WITH (security_invoker = on)`. Después hay que verificar `reloptions`.
- **Se aprovecha para alinear el redondeo del total:** hoy el RPC suma las líneas sin redondear y la pantalla suma las líneas redondeadas. Pueden diferir en 0,01, que es justo el tipo de diferencia que el ajuste quiere cerrar. Hoy no pasa en ninguna factura. Propuesta: que el RPC sume `ROUND(línea, 2)`, igual que la pantalla y que `precio_total_sin_iva`.

**Pantallas**

| Archivo | Cambio |
|---|---|
| [totalesCompra.ts](../packages/shared/lib/totalesCompra.ts) | `calcularTotalesFacturaCompra(items, alicuota, ajuste)` → `total = subtotal + IVA + ajuste`. Tests en `totalesCompra.test.ts` |
| [CargarFacturaCompraModal.tsx](../packages/shared/src/components/CargarFacturaCompraModal.tsx) (Local y Gestión) | Renglón "Ajuste por redondeo" en el pie, entre IVA y Total. `MontoInput negativo`, vacío = 0. Sirve para artículos y servicios |
| [CargarFacturaPage.tsx](../apps/virikyna-inventario/src/pages/Facturas/CargarFacturaPage.tsx) (Inventario, celular) | El mismo renglón en el resumen |
| [facturasCompra.ts](../packages/shared/lib/facturasCompra.ts) | `ajusteRedondeo` en `ValoresFacturaCompra`, `CargarFacturaCompraInput` y `parametrosFacturaCompra` (viaja solo si ≠ 0). Borradores viejos sin el campo = 0 |
| `FacturaCompraDetalleModal.tsx` (Local y Gestión) | Muestra "Ajuste por redondeo: −$ 0,02" si ≠ 0 |
| [EditarFacturaCompraModal.tsx](../packages/shared/src/components/EditarFacturaCompraModal.tsx) | Campo de ajuste, bloqueado con pagos aplicados (igual que el IVA) |
| `types/database.ts` | `ajuste_redondeo: number` en `FacturaCompra` / `FacturaCompraSaldo` |

### Parte B: ajuste en pagos y cobros

**Base**
- `pagos_proveedor.ajuste_redondeo` y `pagos_cliente.ajuste_redondeo`, `NUMERIC(12,2) NOT NULL DEFAULT 0`.
- Regla: **lo que el pago cancela = monto (plata) + ajuste.** `monto` sigue siendo solo plata, así que egresos, medios, cuentas y cierres no cambian.
  - Ajuste **positivo**: faltaron centavos y se dan por pagados. Ejemplo: factura 10.000,02, pago 10.000 + ajuste 0,02 → la factura queda pagada.
  - Ajuste **negativo**: sobraron centavos y no quedan a cuenta. Ejemplo: pago 10.000,05 − ajuste 0,05 → cancela 10.000.
- `registrar_pago_proveedor_v3` y `registrar_cobro_cliente` reciben `p_ajuste_redondeo DEFAULT 0` (`DROP` y `CREATE` por el cambio de firma). Reparten `monto + ajuste`. **Validaciones (no son topes):**
  - un ajuste positivo tiene que quedar aplicado entero a comprobantes, porque si no generaría saldo a favor sin plata;
  - `monto + ajuste > 0`;
  - en cobros, `monto + ajuste ≤ saldo_cobrable`, la regla que ya existe.
- **Ajuste solo, sin plata:** permitido si el ajuste es positivo y hay comprobantes con saldo. Sirve para cerrar centavos que quedaron de antes. No genera egresos, medios ni movimientos de cuenta, y en Local no exige caja abierta. El cierre de Local no lo cuenta, porque une con `pagos_cliente_medios` y un ajuste solo no tiene medios.
- `forma_pago` es NOT NULL en las dos tablas. Para un ajuste solo, propongo permitir NULL **solo** si `monto = 0` y `ajuste_redondeo ≠ 0`, con un CHECK. Así se evita agregar un valor a un enum (`ALTER TYPE … ADD VALUE` no se puede probar con ROLLBACK, ver docs/68) y que "ajuste" aparezca como medio en los reportes.
- Vistas que suman `monto + ajuste_redondeo`: `proveedores_saldo`, `clientes_saldo`, `pagos_proveedor_a_cuenta` (y con ella `proveedores_a_cuenta`) y `pagos_cliente_a_cuenta`. "Vigente" pasa a ser `monto + ajuste > 0` y no ser una reversión. Todas se recrean con `security_invoker = on`.
- `revertir_movimiento`: la reversión copia el ajuste en negativo, así revertir un pago con ajuste lo deja todo como estaba.
- `aplicar_pagos_a_cuenta`, `aplicar_cobros_a_cuenta` y `desaplicar_*` toman el "a cuenta" de las vistas, así que siguen andando sin cambios. Se verifica en las pruebas.

**Pantallas**

| Archivo | Cambio |
|---|---|
| [PagarProveedorModal.tsx](../packages/shared/src/components/PagarProveedorModal.tsx) | Renglón "Ajuste por redondeo" debajo de los medios, más un botón **"Ajustar la diferencia"** que lo completa con `saldo elegido − plata`. La vista previa muestra "Cancela $ X = plata $ Y + ajuste $ Z". Se puede guardar sin medios si hay ajuste |
| [CobrarClienteModal.tsx](../packages/shared/src/components/CobrarClienteModal.tsx) | Lo mismo |
| [ProveedorCuentaCorriente.tsx](../packages/shared/src/components/ProveedorCuentaCorriente.tsx), [ClienteCuentaCorriente.tsx](../packages/shared/src/components/ClienteCuentaCorriente.tsx) | En la lista de pagos y cobros, el ajuste aparece al lado del monto ("$ 10.000 + ajuste $ 0,02"). Un ajuste solo se muestra como "Ajuste por redondeo" |
| Historial | Mismo rótulo para un pago o cobro sin plata |
| `types/database.ts` | `ajuste_redondeo` en `PagoProveedor` / `PagoCliente`; `forma_pago` nullable |

### Permisos

| Acción | Quién |
|---|---|
| Cargar un comprobante con ajuste | Admin y cajero, igual que hoy cargar comprobantes |
| Pagar o cobrar con ajuste, o ajuste solo, desde la caja de Local | Admin y cajero |
| Pagar o cobrar desde Gestión (origen `general`) | Solo admin, igual que hoy |
| Cambiar el ajuste de un comprobante ya cargado | Solo admin: es parte de editar la factura, y hoy editar es solo de admin |

**Sin tope de importe**, como pidió la dueña. Las validaciones de arriba no limitan el monto: evitan que el ajuste invente saldos a favor o deje totales negativos.

El ajuste queda registrado en la fila del comprobante o del pago, así que la auditoría y el Historial lo muestran con usuario y fecha.

## 4. Decisiones para confirmar

| # | Tema | Propuesta |
|---|---|---|
| D1 | Rótulo | "Ajuste por redondeo" en todos lados |
| D2 | Copiar una factura | **No copia el ajuste**: es propio de cada comprobante. La copia arranca en 0 |
| D3 | Editar el ajuste de una factura ya cargada | Solo admin y solo sin pagos aplicados (igual que el IVA) |
| D4 | Ajuste solo, sin plata | Sí, desde el mismo modal de pago o cobro, solo positivo (baja deuda). Para centavos que quedaron **a favor** de un pago viejo: revertir ese pago y cargarlo de nuevo con ajuste negativo. Hoy no hay ninguno |
| D5 | Total del RPC | Sumar las líneas redondeadas, igual que la pantalla (punto A) |
| D6 | NC con ajuste | Permitido: el ajuste suma o resta al total de la NC, que es el crédito |

## 5. Plan de trabajo (una sola entrega)

1. **Migración `docs/71_ajuste_redondeo.sql`.** Antes de crearla hay que volver a listar `docs/`, porque los números chocan entre sesiones. Contiene las columnas, los CHECK, las 5 funciones (cargar, contado, editar, pago v3, cobro), `revertir_movimiento` y las 6 vistas, con tests en un bloque `BEGIN … ROLLBACK`.
2. **Prueba en la restauración local** (`:54329`), con la migración entera. Hay `DROP FUNCTION` y CHECK nuevos, y la prueba incluye: carga con ajuste ±, contado con ajuste, edición de alícuota que conserva el ajuste, pago y cobro con ajuste ±, ajuste solo, reversión desde el Historial y cierre de Local sin cambios.
3. **Backup** y después **aplicar en producción**.
4. **Pantallas** (`packages/shared` + Inventario), con tests de `totalesCompra` y `tsc` de las tres apps.
5. **Publicar:** Gestión e Inventario con push a `main`, Local con un release (3 archivos de versión + tag).

**Orden seguro:** primero la migración y después las apps. Las apps viejas no mandan el parámetro, toman el default 0 y siguen funcionando igual. Hasta que se actualicen, Local viejo muestra el total correcto (ya incluye el ajuste) pero no el renglón, así que en esa versión subtotal + IVA no le va a cerrar visualmente con el total.

## Riesgos

1. **Firmas de RPC:** si queda la versión vieja junto a la nueva, PostgREST da "could not choose the best candidate function". Se resuelve con `DROP` + `CREATE` y se verifica con `pg_proc` que quede una sola.
2. **Vistas:** recrearlas sin `security_invoker = on` reabre el acceso que cerró docs/38. Hay que verificar `reloptions` de las 6.
3. **Sin tope:** un ajuste grande (por ejemplo, −$ 5.000 tipeado de más) pasa. Lo que lo mitiga: el renglón se ve en el pie y en el detalle, queda en la auditoría con el usuario, y el contado muestra el total antes de pagar.
4. **Local viejo:** ver el último párrafo del punto 5.
