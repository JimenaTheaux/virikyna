---
name: pos-inventory-architecture
description: Patrones de modelado de datos para stock e inventario en sistemas de punto de venta y retail. Usar al diseñar el schema de productos/stock de un POS, al decidir cómo registrar movimientos de stock (ventas, compras, ajustes), al manejar múltiples ubicaciones de depósito, o al resolver problemas de stock negativo, carreras de stock (dos ventas simultáneas del mismo producto) o falta de trazabilidad de quién cambió qué. Aplica a cualquier proyecto de inventario/retail, no solo a uno en particular.
---

# Arquitectura de inventario para sistemas POS

## Principio central: el stock es un saldo derivado, no un número que se edita

El error más común es tratar `stock` como una columna que cada acción sobreescribe directamente (`UPDATE productos SET stock = stock - 1`). Esto pierde el historial, es imposible de auditar, y genera bugs sutiles cuando dos operaciones tocan el mismo producto casi al mismo tiempo.

*Este mismo principio aplica a cualquier saldo del negocio, no solo stock — saldo de caja por medio de pago, cuenta corriente de un cliente o proveedor. Si el negocio necesita cargar un "saldo inicial" al migrar de otro sistema, ese principio es lo que lo hace trivial: un saldo inicial es simplemente el primer movimiento del ledger, no un caso especial.*

**Patrón correcto — event log de movimientos:**
- Cada cambio de stock (venta, ingreso por compra, ajuste manual) se inserta como una fila inmutable en una tabla de movimientos (`producto_id`, `tipo`, `cantidad` con signo, `motivo`, `usuario_id`, `referencia_id`, `created_at`).
- El "stock actual" es la suma de esos movimientos — se puede mantener como columna cacheada (actualizada en la misma transacción que inserta el movimiento) para lectura rápida, pero **la fuente de verdad es el log, no el cache**.
- Esto da trazabilidad completa gratis: "¿por qué este producto tiene 3 unidades menos de lo esperado?" siempre tiene respuesta.

## Deltas, no valores absolutos

Nunca sincronizar o escribir stock como un valor absoluto ("este producto tiene 12 unidades") entre cliente y servidor si hay más de un punto de escritura (dos cajas, o una caja + carga desde celular). Sincronizar **deltas** ("-1 por esta venta", "+50 por esta factura de compra"). Un valor absoluto pisa cualquier cambio concurrente que no haya visto todavía; un delta se puede aplicar en cualquier orden y el resultado converge igual.

Esto es crítico en arquitecturas local-first (ver skill `powersync-offline-sync`): si dos cajeros venden el mismo producto mientras ambos están offline, ambas ventas tienen que descontarse — un valor absoluto "ganador" haría desaparecer una de las dos ventas.

## Operaciones atómicas, nunca en el cliente

Toda operación que combina "insertar un movimiento" + "actualizar el stock cacheado" + "insertar la fila de negocio que lo origina" (venta, factura de compra, ajuste) debe vivir en **una sola función atómica del lado del servidor** (RPC en Postgres, función `SECURITY DEFINER`, o transacción explícita). Nunca hacer esos pasos como llamadas separadas desde el frontend — una falla de red a mitad de camino deja el stock inconsistente con las ventas.

## Multi-ubicación (depósito, sucursal, etc.)

Si el negocio tiene más de una ubicación física de stock:
- El stock **no es una propiedad del producto**, es una propiedad de la combinación `(producto, ubicación)`. Modelarlo como tabla separada (`stock_ubicaciones`), no como columnas `stock_local`, `stock_deposito` en la tabla de productos — agregar una ubicación nueva no debería requerir una migración de schema.
- Cada movimiento de stock lleva su ubicación. Una transferencia entre ubicaciones son dos movimientos (egreso de una, ingreso en otra), no una edición directa.

## Evitar stock negativo sin bloquear la venta

Dos estrategias, elegir según el negocio:
- **Bloqueo duro**: la operación de venta falla si no hay stock suficiente. Correcto para inventario físico donde vender algo que no existe es un error real.
- **Permitir y alertar**: se permite la venta igual (el negocio puede preferir vender y ajustar después, ej. mercadería en tránsito) pero se marca el movimiento y se dispara una alerta. Preguntar al cliente cuál de las dos espera — no asumir.

## Ajustes manuales: siempre con motivo y siempre auditados

Un ajuste de stock (rotura, pérdida, corrección de conteo físico) es la operación con más riesgo de mal uso — es la puerta de atrás para "arreglar" un número sin dejar rastro. Reglas mínimas:
- Motivo obligatorio, de una lista cerrada más un campo libre para "otro".
- Usuario y timestamp siempre registrados — nunca opcional.
- Restringir qué rol puede hacer ajustes (típicamente solo supervisor/admin, no cualquier vendedor) — esto evita que un error de carga se "corrija" silenciosamente por la misma persona que lo cometió.

Si el negocio pide además poder **revertir** cualquier movimiento (no solo verlo en el historial), ese ajuste nunca se deshace sobreescribiendo la fila original — se aplica un movimiento inverso nuevo. Ver la skill `supabase-production-patterns`, sección "Auditoría universal y reversión de acciones", para el patrón completo de implementación (triggers + tabla append-only + reversión como acción nueva).

## Alertas de stock bajo: el umbral vive en el producto, no en el código

El "stock mínimo" que dispara una alerta debe ser un campo editable por producto (`stock_minimo`), nunca un número fijo en el código (`if stock < 5`). Productos de alta rotación necesitan un umbral distinto a los de baja rotación, y esa decisión es del negocio, no del desarrollador.

## Precio de venta como columna derivada, no como dato suelto

Cuando el precio depende de una fórmula (costo + margen(es) + impuesto), calcularlo como columna generada por la base de datos (`GENERATED ALWAYS AS ... STORED` en Postgres) en vez de calcularlo en el frontend y guardarlo como número plano. Esto garantiza que el precio mostrado siempre sea consistente con costo/margen actuales, sin scripts de recálculo masivo cuando cambia una fórmula.

## Snapshot de precio en cada venta

El precio en `producto.precio_venta` cambia con el tiempo. Cada línea de venta debe guardar su propio `precio_unitario` como snapshot del momento de la venta — nunca hacer JOIN al precio actual del producto para mostrar una venta histórica, o los reportes de ventas viejas cambiarían solos cuando cambian los precios de hoy.

## Checklist rápido antes de dar por cerrado un schema de inventario

- [ ] ¿Hay una tabla de movimientos de stock, además del stock cacheado?
- [ ] ¿Las escrituras de stock son deltas, no valores absolutos?
- [ ] ¿Cada operación que toca stock + otra tabla es atómica (RPC), no varias llamadas desde el cliente?
- [ ] ¿El stock está modelado por ubicación si hay más de una?
- [ ] ¿Los ajustes manuales exigen motivo y quedan auditados?
- [ ] ¿El umbral de stock bajo es un campo por producto?
- [ ] ¿El precio de venta es una columna derivada, no un número suelto que puede desincronizarse?
- [ ] ¿Las ventas guardan snapshot del precio, no una referencia al precio actual?
