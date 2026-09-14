---
name: powersync-offline-sync
description: Patrones de implementación para PowerSync (sincronización SQLite local ↔ Postgres/Supabase) — diseño de sync rules, manejo de escrituras offline, resolución de conflictos, y UX de estado de conexión. Usar al definir qué datos sincronizar a cada dispositivo, al decidir cómo resolver conflictos de escrituras concurrentes offline, al mostrar estado de sincronización en la UI, o al diseñar cualquier operación de escritura en una app local-first.
---

# PowerSync — patrones de sincronización offline-first

## El modelo mental correcto: server-reconciliation, no CRDT

PowerSync no usa CRDTs — es sincronización cliente↔servidor (no peer-to-peer), con el servidor como autoridad final. El comportamiento por defecto es "last write wins" a nivel de fila, con la posibilidad de implementar lógica de conflicto propia en el backend. Diseñar asumiendo esto: el cliente escribe local al instante (por eso se siente rápido), la escritura se encola, y eventualmente se aplica contra el servidor — que decide qué pasa si hubo un conflicto real.

## Deltas para todo lo que se pueda sumar/restar — nunca reemplazar un valor absoluto

Este es el punto que más importa en un POS: si dos cajas están offline y ambas venden el último producto en stock, **ambas ventas tienen que registrarse** cuando vuelva la conexión — no puede ganar "la última en sincronizar" y borrar la otra. Esto se resuelve tratando cambios de cantidad (stock, saldo de cuenta corriente) como **deltas que el backend suma/resta**, no como el nuevo valor absoluto que sobreescribe. Ver también la skill `pos-inventory-architecture` — es el mismo principio aplicado al modelado de datos.

## No dejar la escritura cruda en manos del cliente

PowerSync sincroniza lo que hay en Postgres — pero **cómo llega ahí** es responsabilidad del desarrollador (arquitectura "bring your own backend"). No usar el cliente para insertar directamente en las tablas de negocio sin pasar por una función de servidor: la validación, el cálculo de deltas, y el registro de auditoría deben vivir en un endpoint o RPC del backend que procese la cola de escrituras subida por PowerSync, no en un INSERT directo desde SQLite local sin capa intermedia.

## Clasificación de resultados de escritura — importa cuál se devuelve

El SDK de PowerSync distingue el resultado de cada escritura subida, y de eso depende que la cola de subida no se trabe:
- **Éxito**: el cliente marca la operación como completa.
- **Falla transitoria (5xx)**: el SDK reintenta solo, en orden (FIFO) — usar esto solo para errores realmente temporales (timeout, servidor caído), nunca para errores de validación.
- **Rechazo de negocio** (ej. una validación falla): devolver un **2xx con el error en el body**, no un 4xx. Un 4xx bloquea toda la cola de subida esperando que ese ítem se resuelva; un 2xx con error permite que el cliente lo marque como procesado (aunque rechazado) y siga con el resto de la cola.

## Diseñar para idempotencia

Las operaciones pueden llegar más de una vez al backend (reintentos, reconexiones). Cada operación de escritura debe poder aplicarse dos veces sin duplicar su efecto — usar upserts, o un ID de operación que se valida contra un registro de "ya procesado" antes de aplicar el efecto (sobre todo crítico para movimientos de stock o pagos: aplicar el mismo movimiento dos veces por un reintento de red es un bug real, no hipotético).

## UX de estado de sincronización — nunca dejarlo invisible

El usuario necesita saber, sin adivinar, si lo que acaba de hacer ya se guardó en la nube o todavía está solo en su máquina. Mínimo indispensable:
- Indicador de conexión (online/offline/sincronizando) visible en todo momento, no solo cuando falla.
- Estado por operación relevante (una venta, un cierre de caja) — "guardado localmente" vs. "sincronizado" — cuando la diferencia le importa al usuario (ej. antes de cerrar la app o irse del local).
- Ante un rechazo de negocio en una escritura que ya se mostró como exitosa localmente, avisar explícitamente — el peor caso es que el usuario crea que algo se guardó cuando en realidad el backend lo rechazó.

## Probar escenarios offline reales antes de dar por cerrada una funcionalidad

No alcanza con probar con buena conexión. Antes de considerar lista una función de escritura:
- Simular dos clientes offline haciendo cambios que compiten entre sí, reconectar ambos, y verificar que el resultado final es el esperado (no que "algo se guardó", sino específicamente qué se esperaba que pasara).
- Simular una falla a mitad de una operación compuesta (ej. se corta la conexión entre subir una venta y subir su movimiento de stock asociado) — si esas dos escrituras no viajan atómicamente, hay que diseñar explícitamente qué pasa en ese estado intermedio.

## Checklist antes de dar por lista una función de escritura offline-first

- [ ] ¿Los cambios de cantidad/saldo son deltas, no valores absolutos?
- [ ] ¿La escritura pasa por una función de servidor que valida y calcula, no un INSERT directo desde el cliente?
- [ ] ¿El backend devuelve 2xx (con error en el body) para rechazos de negocio, no 4xx?
- [ ] ¿La operación es idempotente si llega duplicada?
- [ ] ¿El usuario puede ver, sin preguntar, si algo ya sincronizó o sigue pendiente?
- [ ] ¿Se probó el escenario de dos clientes offline compitiendo por el mismo recurso?
