# 04 — Módulos y Funciones — Virikyna POS (Fase 1, validado con la clienta)

Roles del sistema: **Admin** (Alicia, Ana Julia) y **Cajero** (Jose, Ale, Belu). Sin bloqueo por intentos fallidos. Sin autorecuperación de contraseña — solo el admin blanquea.

---

## 1. LOGIN

| Acción | Admin | Cajero |
|---|---|---|
| Iniciar sesión | ✅ | ✅ |
| Cambiar de usuario sin cerrar la app | ✅ | ✅ |
| Blanquear contraseña de otro usuario | ✅ | ❌ |
| Crear usuario nuevo | ✅ | ❌ |

**Reglas:** la sesión activa queda asociada a cada venta y a cada cierre de caja, para trazabilidad.

---

## 2. DASHBOARD

**Vista Admin** — panel completo: ventas totales de hoy + variación vs. ayer, cantidad de tickets, ticket promedio, alerta de stock bajo (según mínimo definido por producto), gráfico de ventas de la semana, accesos rápidos (Inventario / Proveedores / Cierre de Caja / Configuración).

**Vista Cajero** — grid de botones grandes: ventas del día (monto simple), alertas de stock bajo, accesos directos (Nueva venta / Inventario / Facturación / Cierre de caja).

**Recuadro "Abrir caja" (docs/21_apertura_caja.sql, ambas vistas de Virikyna Local):** cuando no hay una caja abierta, aparece arriba del grid mostrando el monto esperado de apertura (= efectivo contado del último Cierre Z) y quién hizo ese Cierre Z (usuario y fecha/hora) — o el aviso de que todavía no hay ningún Cierre Z si es la primera apertura del sistema. El cajero elige **Confirmar** (abre con ese mismo monto) o **Modificar monto** (ingresa el monto real que tiene y abre con ese valor). Mientras la caja sigue abierta, el recuadro muestra el estado en su lugar (monto real y desde cuándo) — no se puede volver a abrir hasta el próximo Cierre Z.

**Alerta de diferencia de apertura (dashboard de Virikyna Gestión, exclusivo Admin):** si un cajero abrió la caja con un monto distinto al esperado, aparece un aviso "⚠ Apertura de caja con diferencia de $X (sobró/faltó) — usuario, fecha/hora" apenas la dueña entra al dashboard. El detalle completo (quién abrió, cuándo, monto esperado, monto real) queda accesible desde el historial de caja: al ver el detalle de cualquier Cierre X o Z (Cierre de Caja en Local, Tablero de Cierres en Gestión) se muestra la sección "Apertura del período" con esos datos.

---

## 3. VENTAS

**Atajos de teclado:**

| Tecla | Acción |
|---|---|
| Enter | Confirmar venta |
| E | Pago en efectivo |
| T | Transferencia (Mercado Pago) |
| Q | Pago con QR (Galicia) |
| C | Tarjeta débito/crédito (Galicia) |
| D | Aplicar descuento |
| R | Aplicar recargo |
| Esc | Cancelar venta en curso |

| Acción | Admin | Cajero |
|---|---|---|
| Agregar producto (código o búsqueda) | ✅ | ✅ |
| Editar cantidad de un ítem | ✅ | ✅ |
| Eliminar ítem del carrito | ✅ | ✅ |
| Aplicar descuento | ✅ | ✅ |
| Aplicar recargo | ✅ | ✅ |
| Cambiar cliente (consumidor final / cta. cte.) | ✅ | ✅ |
| Cancelar venta en curso | ✅ | ✅ |
| Agregar nota a la venta | ✅ | ✅ |
| Seleccionar forma de pago | ✅ | ✅ |
| Cobrar (confirmar venta) | ✅ | ✅ |
| Manejar tickets en espera (crear, cambiar, eliminar, cobrar) | ✅ | ✅ |

**Reglas:**
- Aunque el comprobante esté avanzado, se puede cambiar cliente y forma de pago sin arrancar de cero.
- **Cobrar registra la venta y el pago, y genera un Comprobante X** — no dispara automáticamente la Factura C.
- El Comprobante X se puede descargar en PDF, o enviar por Gmail y/o WhatsApp (con +54 pre-cargado, pidiendo mail o celular al enviar).
- No se contempla nota de crédito de venta en Fase 1.

**Tickets en espera:**
- Barra de tabs arriba de la pantalla de Ventas — un ticket por cliente/venta en curso, hasta 5 simultáneos. Cada uno guarda su propio carrito, cliente, descuento/recargo y nota, sin pisar a los demás.
- El botón "+ Nuevo ticket" se deshabilita al llegar a 5, con aviso de que hay que cerrar o eliminar uno para abrir otro.
- Por ticket: click para continuar, menú "⋮" con "Cerrar / Cobrar" (arranca el flujo de cobro para ese ticket puntual) y "Eliminar" (pide confirmación — se pierden los productos cargados).
- Al confirmarse una venta, ese ticket se cierra y desaparece de la barra. Si era el único abierto, se crea uno nuevo vacío automáticamente — la pantalla de Ventas nunca queda sin ningún ticket.
- Los tickets abiertos se guardan localmente (localStorage) y se recuperan al reabrir la app o después de un corte de luz.

---

## 4. FACTURACIÓN (pestaña separada de Ventas)

**Objetivo:** que el cajero decida qué ventas se facturan formalmente y cuándo.

**Qué debe ver:** listado de Comprobantes X con estado "Sin facturar" / "Facturada", filtro por fecha, por medio de pago, con checkboxes para selección múltiple y monto total de lo tildado.

| Acción | Admin | Cajero |
|---|---|---|
| Ver listado de comprobantes | ✅ | ✅ |
| Filtrar por fecha / estado / medio de pago | ✅ | ✅ |
| Seleccionar comprobante(s) para facturar | ✅ | ✅ |
| Emitir Factura C electrónica (ARCA) | ✅ | ✅ |
| Ver y enviar el comprobante de Factura C (mail / WhatsApp) | ✅ | ✅ |
| Ver historial de comprobantes emitidos | ✅ | ✅ |

**Reglas (confirmadas):**
- **Un Comprobante X = una Factura C.** Si se tildan varios comprobantes juntos, el sistema emite una Factura C por cada uno — no se agrupan en un solo comprobante fiscal.
- Sin impresora fiscal: toda la facturación pasa por ARCA electrónica. Si no hay internet al momento de facturar, la emisión queda pendiente hasta que vuelva la conexión (la venta ya está cobrada y no se ve afectada).

---

## 5. INVENTARIO Y STOCK

| Acción | Admin | Cajero |
|---|---|---|
| Ver listado de productos | ✅ | ✅ |
| Alta de producto | ✅ | ✅ |
| Editar producto (precio, proveedor) | ✅ | ✅ |
| Eliminar producto (error de carga, con confirmación) | ✅ | ✅ |
| Dar de baja producto (inactivar) | ✅ | ✅ |
| Reactivar producto inactivo | ✅ | ✅ |
| **Ajustar stock manualmente (con motivo)** | ✅ | ❌ |
| Actualización masiva de precios (por ítems o por proveedor, %) | ✅ | ✅ |

**Dos formas de "quitar" un producto:**
- **Eliminación** — solo para corregir un error de carga reciente, con modal de confirmación explícito.
- **Baja lógica** — estado "Inactivo": no aparece en el buscador de Ventas, pero conserva su historial.

**Stock por ubicación (confirmado):** existen **2 ubicaciones físicas — Local y Depósito.** El stock se cuenta y se muestra por separado en cada una, no como un total único.

**Reglas de stock:**
- Se descuenta automático al confirmar una venta (de la ubicación correspondiente).
- Se suma automático al cargar una factura de compra de proveedor, en la ubicación indicada por ítem.
- El ajuste manual requiere motivo obligatorio (rotura, pérdida, corrección, otro) + fecha + usuario — solo lo hace el admin.

**Ficha de producto — campos:**
- Nombre, descripción, proveedor, marca
- Código de barras (si tiene) o código interno generado
- Costo (precio de compra, lo carga el cajero/vendedor)
- **Margen en dos casilleros** (ej. 100 + 20) — ver regla de precios abajo
- Stock mínimo (define cuándo se dispara la alerta de stock bajo)
- Stock por ubicación (Local / Depósito)

**Regla de precios y márgenes (importante):**
- El vendedor solo carga el **costo**. El margen es decisión de gerencia, no del vendedor — evita errores de carga (ya ocurrió un caso real).
- Precio de venta = `costo × (1 + margen_1%) × (1 + margen_2%) × (1 + IVA 21%)`.
- El margen tiene un **valor por defecto a nivel proveedor** — los productos nuevos de ese proveedor lo heredan automáticamente.
- Se puede hacer **override individual** del margen en un producto puntual, sin afectar el default del proveedor.

### 5.1 — Inventario y Stock desde celular

Mismo cuadro de acciones que Inventario de escritorio (excepto ajuste de stock, exclusivo admin, se mantiene igual). Login compartido con el sistema principal; acceso directo post-login a "Inventario". Lectura de código de barras con la cámara del celular (Android e iOS). Acceso directo a carga de facturas de proveedores desde el mismo lugar.

---

## 6. PROVEEDORES

| Acción | Admin | Cajero |
|---|---|---|
| Ver listado de proveedores | ✅ | ✅ |
| Alta de proveedor | ✅ | ✅ |
| Editar proveedor | ✅ | ✅ |
| Asociar productos a un proveedor | ✅ | ✅ |
| Cargar factura de compra | ✅ | ✅ |
| Registrar pago a proveedor | ✅ | ✅ |
| Ver historial de cuenta corriente | ✅ | ✅ |
| Eliminar proveedor | ✅ (exclusivo Admin) | ❌ |
| **Editar datos de una factura ya cargada** (fecha, número, tipo, forma de pago — no ítems/montos) | ✅ (exclusivo Virikyna Gestión) | ❌ |
| **Anular una factura cargada por error** (revierte el stock que había sumado) | ✅ (exclusivo Virikyna Gestión) | ❌ |

**Sobre editar/anular (exclusivo Virikyna Gestión):** editar una factura solo corrige datos descriptivos (fecha, número, tipo de comprobante, forma de pago) — si el error está en los ítems o montos, se anula la factura completa (repone el stock que había sumado) y se vuelve a cargar bien. Anular no funciona si la factura ya tiene pagos registrados — primero hay que resolver esos pagos.

**Regla (agregada en QA):** un proveedor con historial (facturas de compra o pagos ya cargados) no se puede eliminar — protegido a nivel base, mismo criterio que ya existía para Clientes.

**Ficha de proveedor:** razón social, CUIT, dirección, teléfono, mail, contacto, **saldo inicial** (deuda con la que arranca en el sistema, cargada una vez desde Caja Gestión).

**Carga de factura de compra — campos:**
- Proveedor (de su ficha)
- Tipo de comprobante: **factura** (con respaldo fiscal) / **remito, presupuesto o cupón** (sin respaldo fiscal — igual suman a stock y a la deuda con el proveedor, la clasificación es solo qué papel se recibió, no una decisión de negocio) / nota de crédito / nota de débito
- Letra: A, B, R, X
- Punto de venta y número de comprobante
- Fecha del comprobante y fecha fiscal
- Forma de pago: contado o cuenta corriente
- Por ítem: cantidad, descripción, precio unitario sin IVA, % descuento, precio total sin IVA, **depósito (Local o Depósito)**
- Ítem libre/en blanco para conceptos genéricos (ajustes, descuento general, o agrupar como "juguetes varios")
- Totales al pie: total sin IVA, IVA, total final

**Reglas:**
- Cargar una factura de compra actualiza el stock automático de esos productos, en la ubicación indicada por ítem. Queda registrado qué usuario realizó la carga.
- Registrar un pago a proveedor genera una **salida de dinero** → se refleja como egreso en el Cierre de Caja del día, y afecta la cuenta corriente del proveedor.
- Pago a proveedores: efectivo, transferencia, cheque físico o echeq.

**Detalle y saldo por factura:** cada factura de compra muestra su propio saldo pendiente (total facturado − suma de pagos aplicados a esa factura puntual) y el historial de pagos que se le hicieron — no solo el saldo general del proveedor. Un pago puede quedar aplicado a una factura específica, o a la cuenta general del proveedor sin apuntar a ninguna en particular (por ejemplo, un pago a cuenta antes de que llegue la factura).

**Dos puntos de entrada, una sola operación real:** el cajero puede registrar un pago a proveedor desde dos lugares distintos en la UI —
1. Desde el detalle de una factura puntual ("Registrar pago" sobre esa factura), o
2. Desde el registro de un egreso (elige categoría "Pago a proveedor" y ahí selecciona a qué proveedor y, opcionalmente, a qué factura corresponde).

Ambos caminos ejecutan la misma función del sistema — no son dos flujos distintos con lógica separada. Se decide cuál mostrar primero según lo que sea más natural para el cajero en cada pantalla, pero el resultado (pago registrado + egreso generado + factura actualizada) es siempre el mismo.

---

## 6.5 INICIO DE CAJA (APERTURA)

**Qué resuelve:** hasta docs/20, `cerrar_caja` calculaba el efectivo esperado asumiendo que el cajón arrancaba en $0 — no había ningún registro de con cuánto efectivo físico empezaba cada turno. La apertura de caja (docs/21_apertura_caja.sql) cubre ese hueco: al empezar el turno, el cajero confirma o corrige el monto real con el que arranca, y ese monto pasa a ser la base del efectivo esperado durante todo el período, hasta el próximo Cierre Z.

**Flujo:** ver el recuadro "Abrir caja" del dashboard (módulo 2). El cajero elige Confirmar (coincide con lo que tiene físicamente) o Modificar (ingresa el monto real). Si modifica, el sistema guarda automáticamente `monto_esperado` (el del Cierre Z anterior), `monto_real_apertura` (el ingresado) y la `diferencia` — visible como alerta en el dashboard de la dueña y como detalle en el historial de caja.

**Una sola apertura por período:** no se puede abrir la caja de nuevo mientras ya hay una abierta — queda abierta desde ese momento hasta el próximo Cierre Z, que la cierra automáticamente.

**Impacto en los cálculos de caja:** todos los cierres (X y Z) y retiros de efectivo del período usan `monto_real_apertura` como base del efectivo esperado — **no** el monto esperado. Es decir: `efectivo_esperado = monto_real_apertura + ventas en efectivo − egresos en efectivo − retiros de efectivo`, el mismo criterio que ya usaban egresos y retiros (docs/17), ahora con la apertura como punto de partida en vez de $0.

| Acción | Admin | Cajero |
|---|---|---|
| Abrir caja (confirmar o modificar monto) | ✅ | ✅ |
| Ver alerta de diferencia de apertura (dashboard) | ✅ (Gestión) | ❌ |
| Ver detalle de apertura de un cierre (historial) | ✅ | ✅ |

---

## 7. CIERRE DE CAJA

**Qué debe ver:** total vendido desglosado por medio de pago (efectivo / cuenta Mercado Pago / cuenta Galicia / cta. cte.), total de egresos del día (pagos a proveedores, otros gastos, retiros), monto esperado en caja (efectivo) según el sistema — incluye el monto real de apertura del período (módulo 6.5) como base —, campo para ingresar el efectivo contado, diferencia (coincide / sobra / falta y por cuánto), usuario que hizo el cierre.

**Regla de cálculo (corregida en QA):** el "efectivo esperado" es el monto real de apertura del período más ventas en efectivo menos **solo los egresos pagados en efectivo** — un egreso pagado por transferencia, cheque o echeq no debe descontarse del cajón físico, aunque sí forma parte del total general de egresos que se muestra como referencia.

**Regla de impacto en cuentas (corregida en QA — evita un doble conteo real que hubo):** cada egreso descuenta su cuenta **en el momento en que se registra** (vía `registrar_pago_proveedor` o `registrar_egreso_general`), nunca de nuevo al validar el Cierre Z. `validar_cierre_z` solo vuelca **transferencia, QR y tarjeta** del día a las cuentas — los egresos ya impactaron antes.

**El efectivo NO se vuelca a Caja Gestión vía Cierre Z (docs/14_retiro_efectivo_caja.sql):** el Cierre Z solo informa cuánto efectivo hay físicamente en el cajón (efectivo esperado / contado / diferencia) — nunca lo suma a ninguna cuenta real. El único camino por el que ese efectivo llega a Caja Gestión es el botón **"+ Retiro"** del Cierre de Caja: el cajero registra fecha, importe, qué admin lo recibe (selector) y qué cajero lo entrega (autocompleta con el usuario logueado, editable), y eso genera un ingreso inmediato en la cuenta Efectivo (`registrar_retiro_caja`). Un retiro es independiente del Cierre Z — no bloquea ni depende de que el día esté cerrado.

| Acción | Admin | Cajero |
|---|---|---|
| Cierre X (parcial, por turno, se repite) | ✅ | ✅ |
| Cierre Z (cierre del día, uno solo) | ✅ | ✅ |
| Registrar egreso (pago a proveedor, gasto varios) | ✅ | ✅ |
| Registrar retiro de efectivo (entrega a un admin) | ✅ | ✅ |
| Ingresar efectivo contado | ✅ | ✅ |
| Ver historial de cierres | ✅ | ✅ |

**"Registrar egreso" es una sola función para todo el sistema (`registrar_egreso_general`), con dos orígenes posibles:** el cajero la usa durante su turno (`origen='turno'`, asociado a su cierre de caja), la dueña la usa desde Caja Gestión para sueldos/servicios (`origen='general'`, sin cierre asociado) — misma función, mismo impacto inmediato en la cuenta, no dos mecanismos separados. Un pago a proveedor siempre pasa por `registrar_pago_proveedor` en cambio (necesita factura/proveedor asociado), nunca por esta.

**Reglas:** Cierre X es una foto del estado actual, por turno, no bloquea la caja. Cierre Z es único por día, al final de la jornada, y cierra la fecha definitivamente.

### 7.1 — Caja Gestión (exclusivo Admin)

**Estructura de navegación (reorganizada tras testeo manual):**
1. **Resumen Cuentas** (submenú por defecto) — dashboard visual con una card por cuenta (Efectivo, Mercado Pago, Galicia) mostrando su saldo actual (vista `cuentas_saldo`). Es la foto rápida de "cuánta plata hay en cada lado".
2. **Movimientos Manuales** — versión reducida de esas mismas cards (solo referencia, no el foco de la pantalla) + los accesos para registrar ingreso/egreso manual, transferir entre cuentas, y el historial de movimientos.
3. **Tablero de Cierres** — ve el resumen de todos los Cierres X/Z hechos desde Virikyna Local, con acceso al detalle de cada uno, y **valida** los Cierres Z. **Gestión no genera Cierres X/Z propios** — no opera caja física, solo audita y valida lo que ya cerró un cajero en Local.

**Módulo aparte: Egresos** (exclusivo Admin, navegación de primer nivel, no una sub-pestaña de Caja Gestión):
- Pantalla para **registrar** nuevos egresos generales de la sucursal (sueldos, servicios — vía `registrar_egreso_general`, `origen='general'`). Estos descuentan directo de la cuenta correspondiente, **sin mezclarse** con los egresos de turno que carga un cajero desde el Cierre de Caja de Local (`origen='turno'`).
- Historial único de egresos, con filtro por rango de fecha (inicio/fin) y filtro por origen (Gestión / Local / Todos) — una sola tabla, no dos, para poder ver todo junto o aislar una fuente puntual.

**Lo que ya existía, sin cambios de fondo:**
- Gestión completa de Proveedores (ver listado con saldo, detalle de factura con saldo pendiente e historial de pagos, registrar pagos, editar/anular factura) — mismas acciones y misma función que usa el cajero desde Local.
- Carga inicial del sistema (una sola vez, al arrancar): saldo por cuenta, saldo inicial de proveedores y clientes.
- Editar/eliminar cualquier movimiento de cuenta: nunca se pisa ni se borra el original — siempre un contra-asiento, visible en el Historial (módulo 10).

**Mapeo de medios de pago → cuenta (confirmado con la dueña):**

| Medio de pago | Cuenta |
|---|---|
| Efectivo | Efectivo |
| Transferencia | Mercado Pago |
| QR | Galicia |
| Débito | Galicia |
| Crédito | Galicia |

*Cuenta corriente no mapea a ninguna cuenta — no entra plata real hasta que el cliente paga esa deuda después (ahí sí impacta, según la forma de pago con la que la salda).* Este mapeo se administra por SQL, no tiene pantalla propia en Fase 1 — está limitado a estas 3 cuentas; sumar una cuenta nueva es una tarea de desarrollo.

| Acción | Admin (Caja Gestión) |
|---|---|
| Cargar saldo inicial por cuenta/formato | ✅ (una vez, al arrancar) |
| Cargar saldo inicial de un proveedor | ✅ |
| Cargar saldo inicial de un cliente | ✅ |
| Registrar ingreso manual en caja general | ✅ |
| Registrar egreso manual en caja general | ✅ |
| Transferir plata entre cuentas | ✅ |
| Editar un movimiento de cuenta | ✅ |
| Eliminar un movimiento de cuenta | ✅ |
| Ver historial de movimientos por cuenta | ✅ |

**Regla:** la carga inicial, los movimientos manuales, las transferencias, y toda edición o eliminación quedan registrados como movimientos nuevos — con usuario y fecha, visibles en el módulo de Historial y Auditoría (módulo 10). Nunca es una edición directa de un número: "editar" y "eliminar" desde la UI se resuelven siempre con un movimiento que compensa al anterior, no con un `UPDATE` o `DELETE` real.

**Pagos que ahora impactan en cuentas (cerrado en esta revisión):** cuando un cliente salda su cuenta corriente, o cuando se le paga a un proveedor en efectivo o transferencia, el monto se refleja automático en la cuenta correspondiente — antes esto quedaba fuera del ledger. Un pago a proveedor en cheque o echeq **no** impacta ninguna cuenta (no es plata líquida al momento de registrarse).

---

## 8. CLIENTES (cuenta corriente)

**Qué debe ver:** listado de clientes con saldo visible, detalle con historial de compras a cuenta + pagos.

| Acción | Admin | Cajero |
|---|---|---|
| Ver listado de clientes | ✅ | ✅ |
| Alta de cliente | ✅ | ✅ |
| Editar cliente | ✅ | ✅ |
| Ver historial de cuenta corriente | ✅ | ✅ |
| Registrar pago/cobro de deuda | ✅ | ✅ |
| Eliminar cliente | ✅ | ✅ |

**Ficha de cliente:** razón social, nombre fantasía, CUIT, domicilio, mail, celular — **ningún dato obligatorio por ahora** (se define después si pasan a ser obligatorios). **Saldo inicial** de cuenta corriente cargado una vez desde Caja Gestión.

**Reglas:**
- Cliente con historial no se puede eliminar, solo inactivar.
- Las cuentas corrientes son exclusivas de clientes cargados — un consumidor final no puede tener cuenta corriente.
- Al vender a cuenta corriente se selecciona el cliente; si se cobra en el momento queda saldada, si no se suma al saldo pendiente.
- Si un cliente hace un pago parcial, **el cajero elige a qué venta se aplica** ese pago.
- Sin límite de crédito.

---

## 9. CONFIGURACIÓN (Usuarios y Roles) — exclusivo Virikyna Gestión

Por ahora, solo gestión de usuarios y roles. **Aclarado en QA:** esta pantalla vive únicamente en Virikyna Gestión, igual que Caja Gestión (módulo 7.1) — una admin que necesite crear un usuario o blanquear una contraseña lo hace desde Gestión, no desde la Caja. Virikyna Local no la construye ni como versión reducida.

| Acción | Admin (Virikyna Gestión) | Cajero |
|---|---|---|
| Ver listado de usuarios | ✅ | ❌ |
| Crear usuario | ✅ | ❌ |
| Editar usuario (nombre, rol) | ✅ | ❌ |
| Blanquear contraseña | ✅ | ❌ |
| Desactivar usuario | ✅ | ❌ |

**Usuarios iniciales a crear:**
- Admin: Alicia, Ana Julia
- Cajero: Jose, Ale, Belu

---

## 10. HISTORIAL Y AUDITORÍA (exclusivo Virikyna Gestión — Admin)

**Objetivo:** que la dueña tenga visibilidad total de todo lo que pasa en el sistema — quién hizo qué, cuándo, y poder corregir un error o un movimiento indebido sin depender de un ticket de soporte.

**Qué debe ver:** listado cronológico de todas las acciones del sistema (de todos los usuarios, incluida ella misma). Por cada acción: usuario, módulo/tabla afectada, tipo de acción (alta / edición / eliminación / anulación / reversión), valor anterior → valor nuevo, fecha y hora. Filtros por usuario, por módulo, por tipo de acción, por rango de fechas. Detalle expandible con el cambio completo.

| Acción | Admin (Virikyna Gestión) | Cajero |
|---|---|---|
| Ver historial completo de acciones | ✅ | ❌ |
| Ver detalle de un cambio (antes/después) | ✅ | ❌ |
| Revertir una acción reversible | ✅ | ❌ |
| Dejar nota de corrección sobre un Cierre Z validado | ✅ | ❌ |

**Reglas de reversibilidad (confirmadas):**
- Cambios de campo simple (precio, margen, datos de producto/cliente/proveedor): **siempre reversibles**, restauran el valor anterior.
- Alta de un registro nuevo: revertir = inactivar/eliminar según la regla ya definida para esa entidad.
- Ajuste de stock, egreso, pago, **movimiento de cuenta (ingreso/egreso manual, transferencia entre cuentas, saldo inicial)**: revertir = genera un movimiento inverso (contra-asiento) — nunca se borra el movimiento original. "Editar" un movimiento de cuenta sigue la misma lógica: se anula el original y se crea el corregido, ambos visibles.
- Venta **sin facturar**: revertir = anula la venta y repone el stock.
- Venta **ya facturada** (con CAE de ARCA): **no reversible desde el sistema, y queda así confirmado para Fase 1.** Una factura con CAE es un documento fiscal ya emitido, solo se revierte con una Nota de Crédito — **funcionalidad fuera de alcance de este desarrollo**, documentada como límite conocido para una fase futura.
- Cierre de Caja Z ya validado: **confirmado que no se revierte.** Se permite agregar una nota de corrección visible en el historial, sin reabrir el cierre — esto cubre la necesidad de dejar constancia sin comprometer la integridad contable del día.
- **Revertir nunca borra la acción original del historial** — genera una acción nueva ("Usuario X revirtió la acción de Usuario Y"), visible también en el log.

---

## 11. NOTAS INTERNAS

**Objetivo:** un pizarrón compartido tipo post-it entre el mostrador y la administración — avisos rápidos, recordatorios, pendientes del día a día — sin necesidad de un chat externo.

**Menú:** ítem "Notas" (mismo nombre en Virikyna Local y Virikyna Gestión). Pantalla con título "Notas internas", sin subtítulo.

| Acción | Admin | Cajero |
|---|---|---|
| Ver notas activas | ✅ | ✅ |
| Crear nota nueva | ✅ | ✅ |
| Archivar una nota | ✅ | ✅ |
| Ver notas archivadas | ✅ | ✅ |

**Qué debe ver:** notas activas como cards estilo post-it (fecha de creación arriba, mensaje en el medio, autor abajo, botón "Archivar"), rotando entre los 6 colores de la marca Virikyna (amarillo, rosa, violeta, celeste, verde agua, teal) para que dos cards consecutivas nunca compartan color. Las notas archivadas quedan ocultas por defecto, detrás de un toggle "Ver archivadas" que las muestra en gris y tachadas.

**Reglas:**
- "+ Nueva nota" abre un campo de texto libre; se guarda con `autor_id` = usuario logueado, sin pasos intermedios.
- Cualquier usuario activo (admin o cajero) puede crear, ver y archivar notas — no hay jerarquía de permisos en este módulo, a diferencia del resto del sistema.
- Archivar es la única acción sobre una nota existente en esta fase: no hay edición de mensaje ni reversión a "activa" desde la UI.
- Virikyna Local y Virikyna Gestión leen y escriben la misma tabla (`notas_internas`), pero **cada una ve y crea solo sus propias notas** — separadas por la columna `origen` (`'local'` | `'gestion'`). Una nota creada en Gestión ya no aparece en Local, ni al revés.
- Un cajero no puede ver ni crear una nota de origen `gestion` por ningún medio: la RLS ya lo bloquea a nivel de base de datos, y además el frontend de cada app filtra explícito por su propio origen en la query (no depende solo de RLS).
- Sin auditoría/reversión (módulo 10): una nota interna es texto libre sin impacto contable ni operativo, no un movimiento de negocio.

Ver `docs/06_estructura_de_datos (1).md` (tabla `notas_internas`, vista `notas_internas_con_autor` y la separación por origen, sección 15) y `docs/16_notas_internas.sql` (RLS y vista, a ejecutar en Supabase).

---

## Próximos desarrollos (fuera de esta fase)

- Factura A y B
- **Nota de Crédito de venta** — necesaria para poder revertir fiscalmente una venta ya facturada; hasta que exista, esas ventas quedan visibles en el Historial pero no son reversibles
- Reportes para el área contable
- Resúmenes y dashboard de balance de negocio para administración
- Futuras actualizaciones y nuevas funciones (a demanda)
