# Novedades de Virikyna Local

## 0.11.0 — octubre 2026

> La versión 0.10.0 sigue funcionando y ya está protegida contra la Factura C duplicada. Conviene actualizar para ver el aviso de precios a etiquetar y el Dashboard nuevo.

### Dashboard
- **Aviso de cambios de precio.** Una fila arriba dice cuántos productos tienen un precio distinto al de su etiqueta en el local ("Cambios de precio · N pendientes de etiquetar"). **Ver y marcar** abre la lista: fecha, producto, marca, el precio de la etiqueta y el precio actual, y de dónde vino el cambio (factura, cambio manual, alta). Un producto nuevo aparece como "Sin etiqueta".
- **Marcar etiquetas.** Después de cambiar la etiqueta en el local, tildar el producto y tocar **Etiqueta actualizada**: sale de pendientes. **Marcar todas** marca las que se ven (pide confirmación). Si el precio cambió de nuevo mientras tanto, ese producto no se marca. Lo pueden hacer administradoras y cajeros.
- **Imprimir listado** imprime la lista de pendientes (o lo que se filtró con el buscador) para ir cambiando etiquetas en el local. La pestaña **Últimos 30 días** muestra todos los cambios y quién marcó cada etiqueta.
- **Productos vendidos hoy.** Lista de lo vendido en el día con unidades, importe y stock que queda; **Ver todos** abre la lista completa con buscador y orden.
- **Más compacto.** Entra entero en la pantalla sin bajar: arriba la caja y el aviso de precios, después las ventas, tickets y ticket promedio de hoy; a la izquierda los productos vendidos; a la derecha las ventas de la semana, el stock y los defectuosos.

### Facturación
- **Una venta, una sola Factura C.** Si dos pantallas emiten la misma venta a la vez, solo una le pide la factura a ARCA; la otra avisa "Ya se está emitiendo desde otra pantalla." La factura queda guardada aunque se cierre el programa justo después de emitir.
- **Ventas para revisar.** Si un intento de emisión se cortó a la mitad y no se sabe si ARCA llegó a emitir, la venta queda bloqueada con el aviso "No se pueden emitir hasta que un administrador lo revise". Una administradora la busca en ARCA y, si no tiene factura, la **desbloquea** dejando una nota de qué revisó.

## 0.10.0 — octubre 2026

> Conviene actualizar hoy: en la 0.9.0, un pago a proveedor hecho desde Virikyna Gestión con varios medios (por ejemplo transferencia + cheques) se ve con la forma de pago rota.

### Facturación
- **Se confirma antes de emitir la Factura C.** Antes de pedirla a ARCA se muestra el cliente, el documento que se informa, el ticket, el total y el punto de venta. "Volver" (o Esc) no emite nada. Con varias ventas tildadas, muestra la lista de tickets y el total general.
- **El DNI no se informa.** Si el cliente tiene cargado un DNI (o un CUIT incompleto), el aviso lo dice: la factura sale como consumidor final. Solo un CUIT de 11 dígitos va en la factura.
- **Se emite solo lo que se ve.** Una venta tildada que quedó oculta por el buscador ya no se factura.
- Un doble clic en confirmar no pide dos facturas.

### Inventario
- **Filtros nuevos.** Arriba del listado: buscador (con la "x" para borrar), **Activos / Inactivos / Todos**, **Marca** y **Proveedor** (con buscador adentro), y chips con la cantidad de cada caso: **Sin stock**, **Negativo**, **Stock bajo** y **Sin mínimo**. "Limpiar filtros" vuelve todo a cero. Los filtros quedan guardados: al volver a Inventario siguen igual.
- **Stock con color.** Rojo oscuro si está negativo, rojo si no hay, ámbar si está en el mínimo o debajo; debajo se ve el mínimo ("min 5" o "sin min"). Los productos inactivos se ven más claros y con la etiqueta INACTIVO.
- **Ordenar** por nombre, precio o stock tocando el encabezado de la columna.
- **Stock mínimo, más claro.** El campo ahora se llama "Stock mínimo (alerta)" y explica para qué sirve. Si al dar de alta un producto se carga un mínimo, avisa que no es la cantidad que entra (el stock se suma con la factura o con un ajuste).
- **IVA como estado.** La pantalla de IVA abre con los productos exentos ya tildados: se tilda o destilda y se ve qué cambia. Filtro "Ver solo los exentos" y etiqueta "sin IVA" en las listas. (Solo administradoras.)
- El error "Tildá al menos un producto" ya no queda a la vista cuando ya hay productos tildados.

### Dashboard
- **La alerta de stock mira solo los productos con mínimo cargado.** La card muestra **Sin stock (N) · Stock bajo (N)**; tocando cada uno se abre Inventario con ese filtro.

### Proveedores
- **Pagos con varios medios.** Un pago registrado en Virikyna Gestión con varios medios se ve como "Mixto (N medios)" en la cuenta corriente y en el detalle de la factura; al tocarlo se despliega cada medio con su monto (y en los cheques, el banco y cuándo se cobran). Desde Local los pagos se siguen registrando con un solo medio.

## 0.9.0 — octubre 2026

> La versión 0.8.0 sigue funcionando: se pueden seguir creando y archivando notas, pero no se ven las respuestas. Conviene actualizar.

### Notas
- **Responder una nota.** Cada nota tiene **Responder**: la respuesta queda debajo, en letra chica, y también se puede responder una respuesta (se arma una conversación). Si una nota tiene muchas respuestas, aparece "Ver N respuestas" para desplegarlas.
- **Editar.** Quien escribió una nota (o una respuesta) la puede corregir con **Editar**; queda marcada "· editada". Las notas de otra persona no se pueden editar.
- **Desarchivar.** Las notas archivadas se ven con el botón **Ver archivadas (N)**, arriba a la derecha, y se pueden volver a activar con **Desarchivar**. Archivar o desarchivar una nota lo hace con todas sus respuestas.
- Las notas ya no se pueden borrar: se archivan.

### Facturación
- **Se ve qué se vendió.** En **Ventas del día** y en **Facturación**, debajo de cada venta aparece en gris lo que se llevó ("2× PRODUCTO · 1× PRODUCTO"; si son muchos, "+N más"). Un clic en la venta despliega la lista completa con el importe de cada ítem.
- **Facturación muestra los últimos 30 días.** Sin fechas elegidas, el listado trae las ventas de los últimos 30 días (lo avisa arriba de la tabla). Para ver ventas anteriores, elegir las fechas. Buscar por **N° de ticket** encuentra cualquier venta, aunque sea más vieja (para devoluciones y cambios).

## 0.8.0 — octubre 2026

> La versión 0.7.1 sigue funcionando, pero ahí "Contado" no registra el pago. Conviene actualizar.

### Facturas de compra — pago de contado
- **Contado registra el pago al guardar.** Si la factura se paga de contado, al guardarla queda registrado el pago en efectivo al proveedor, como egreso de la caja del día y a nombre de quien la carga. La factura queda **pagada** y el egreso aparece en el Cierre de Caja.
- **Se confirma antes de grabar.** Antes de guardar se muestra a quién se le paga, el monto, de qué caja sale y el usuario. "Volver" no graba nada.
- **Hace falta la caja abierta.** Sin caja abierta no se puede pagar de contado ("Abrí la caja para pagar de contado"); la factura se puede guardar igual en cuenta corriente.
- **Ahora la forma de pago arranca en cuenta corriente.** Contado se elige a mano. Una nota de crédito queda siempre en cuenta corriente.
- **Todo o nada.** Si el pago no se puede registrar, la factura tampoco se carga (y el borrador sigue disponible).

## 0.7.1 — octubre 2026

### Facturas de compra
- **Vincular a producto actualiza el costo.** Al vincular un ítem sin producto de una factura ya cargada, además de sumar el stock, el producto toma el costo de ese ítem (con su descuento) si es su compra más nueva, igual que si se hubiera elegido al cargar la factura. Si tenía precio manual, el precio vuelve a salir de la fórmula. Si el producto tiene una compra más nueva, solo se suma el stock.
- **Se ve antes de confirmar.** Al elegir el producto, la ventana muestra cómo quedan el costo y el precio de venta (o avisa que solo suma stock).

## 0.7.0 — octubre 2026

> La versión 0.6.1 sigue funcionando con estos cambios. Conviene actualizar para ver las pantallas nuevas y la explicación de cómo una nota de crédito toca el stock.

### Cierre de Caja
- **Tablas nuevas, iguales a las de Virikyna Gestión.** Egresos, retiros y Cierres X se ven en tablas con encabezado, filas alternadas y el total al pie.
- **Se ve a qué proveedor se le pagó.** Los egresos de "Pago a proveedor" muestran la razón social en su propia columna.
- **El monto contado se muestra como va a quedar.** Debajo del efectivo contado del Cierre Z y del monto de apertura aparece "Se va a registrar: $ …", para notar antes de confirmar si el punto se tomó como decimal.

### Proveedores — pagos a cuenta
- **Aplicar pagos a cuenta.** Si a un proveedor se le pagó sin tener comprobantes (la plata quedó "a cuenta"), ahora se puede aplicar después: en su cuenta corriente aparece **Aplicar a comprobantes** (a los seleccionados o a los más viejos). No mueve plata ni toca la caja.
- **Al cargar una factura** de un proveedor con plata a cuenta, se ofrece aplicarla en el momento.
- **Aviso al registrar un pago:** "Este proveedor tiene $ … a cuenta", para no pagar dos veces.
- En la cuenta corriente se ve el total **A cuenta (pagos)**. Quitar una aplicación se hace desde Virikyna Gestión (administradores).

### Facturas de compra
- **Facturas de servicios.** Al cargar se elige **Artículos** o **Servicios**. Una factura de servicios (flete, mantenimiento, honorarios) lleva solo descripción e importe: no pide cantidad ni producto y no mueve stock. El tipo queda fijo y se ve como chip en los listados; la cuenta corriente se puede filtrar por tipo.
- **Borradores.** Una factura a medio cargar ya no se pierde al cerrar la ventana, la app o con un corte de luz: se guarda sola como borrador. Al cerrar se puede **Guardar borrador**, **Descartar** o **Seguir editando**. Los borradores aparecen arriba del listado con el chip **Borrador** y se retoman desde ahí. No mueven stock, saldos ni caja hasta confirmarlos.
- **Notas de crédito y stock.** Una nota de crédito ya **no suma stock**. Si la mercadería se devuelve al proveedor, se marca **Devolución de mercadería** y resta la cantidad de cada ítem en su depósito. Si se anula la nota, se revierte exactamente lo que movió.

### Búsquedas
- **Sin acentos en todo el sistema.** Los textos se guardan sin tildes (la Ñ se conserva) y las búsquedas los ignoran: "línea" encuentra "LINEA".

## 0.6.1 — octubre 2026

### Facturas de compra
- **Aviso cuando un ítem no va a sumar stock.** Si se escribe el nombre de un producto pero no se elige de la lista, el ítem queda sin vincular al inventario y no suma stock. Ahora se avisa en el mismo renglón, con **Buscar en el inventario** y **Crear producto nuevo**.
- **Confirmación al guardar.** Si la factura tiene ítems sin producto, antes de guardar se listan y hay que elegir **Volver y vincular** o **Guardar sin sumar stock** (para fletes, ajustes o "varios").
- **Vincular a producto (solo administradores):** en el detalle de la factura, un ítem sin producto muestra "Sin producto: no sumó stock" y el botón **Vincular a producto**. Se elige el producto y se suma la cantidad del ítem al stock, una sola vez. Si después se anula la factura, ese stock también se descuenta.

## 0.6.0 — octubre 2026

### Actualizaciones
- **La app ya no se reinicia sola para actualizarse.** La versión nueva se descarga en segundo plano y aparece el aviso "Hay una versión nueva" con **Reiniciar ahora** o **Después**. Si hay un formulario con cambios sin guardar, pregunta antes; si se está cobrando, espera a que termine.

### Formularios
- **Ya no se cierran ni se pierden datos solos.** Antes, más o menos una vez por hora, la pantalla se recargaba y se perdía lo que se estaba cargando. Eso ya no pasa.
- Esc no cierra un formulario. La ✕ y "Cancelar" preguntan antes de cerrar si hay cambios sin guardar. En las ventanas de solo lectura (detalles), Esc sigue cerrando.

### Facturas de compra
- **IVA por comprobante: "IVA 21%" o "Exento".** Se elige junto a los totales al cargar la factura. Factura, nota de crédito y nota de débito arrancan con 21%; cupón, remito y presupuesto, exentos. Se puede cambiar a mano, y el total y la deuda con el proveedor salen con el IVA elegido.
- El detalle de la factura y la cuenta corriente del proveedor muestran si el comprobante es con IVA o exento. Al copiar una factura se copia también su IVA.
- **El costo del producto tiene en cuenta el descuento de la línea.** Un ítem a $1.000 con 10% de descuento deja el costo en $900 (antes quedaba en $1.000). El aviso de cambio de precio lo muestra igual.
- En el detalle de una factura los botones quedan siempre a la vista, también en pantallas chicas.

### Productos
- **"Lleva IVA":** en el formulario de producto hay un interruptor para indicar si el precio de venta lleva IVA. Al cambiarlo se ve el precio nuevo antes de guardar. Un producto con precio manual no cambia de precio hasta que tenga costo cargado. Solo un administrador lo cambia.
- **IVA de varios productos a la vez:** en Inventario, tildar los productos y tocar **IVA** → "Marcar con IVA" o "Marcar sin IVA", con vista previa de cómo queda cada precio y confirmación. Solo administradores.
- **Eliminar producto (solo administradores):** botón "Eliminar" en el formulario. Si el producto ya tiene ventas, compras o movimientos de stock, no se puede eliminar y se ofrece **Inactivarlo**.
- **Producto sin código de barras:** al darlo de alta se le asigna un código numérico de 13 dígitos (empieza con 20), el mismo tipo que usa la carga inicial, que se puede imprimir y escanear.

### Escaneo con cámara
- La cámara lee solo números: descarta lecturas con letras y saca el prefijo que agregan algunas etiquetas (por ejemplo "]C1"). Escribir el código a mano en el escáner también acepta solo números. El lector de la caja funciona igual que antes.

## 0.5.2 — octubre 2026

### Inventario
- **Ahora se ven todos los productos.** La lista de Inventario mostraba solo los primeros 1000 (hasta la L): los demás no aparecían ni buscándolos, aunque estaban cargados y se podían vender. Ahora carga la lista completa. Lo mismo en Virikyna Gestión y en la app Inventario del celular.

## 0.5.1 — octubre 2026

### Ventas
- **Productos más fáciles de leer en la búsqueda y el carrito:** arriba el NOMBRE con el precio a la derecha; abajo, más chico, la marca, el código y la descripción. Los nombres largos pasan al renglón de abajo en vez de cortarse.
- En el carrito el precio unitario quedó al lado del nombre; las columnas Cant. e Importe siguen igual.

### Devoluciones y compras
- Devolución / Cambio y las sugerencias de producto al cargar una factura de compra usan el mismo formato. En la factura se muestra el costo actual en vez del precio de venta.

## 0.5.0 — octubre 2026

### Productos
- **Formato fijo del texto:** el nombre y la marca de los productos se guardan siempre en MAYÚSCULAS, y la descripción con solo la primera letra en mayúscula ("Auto de spiderman"). Se puede tipear como sea: el sistema lo acomoda solo. Los códigos se guardan tal cual.
- **Tabla de Inventario más simple:** Nombre, Marca, Descripción, Precio de venta, Stock y Estado. Proveedor, costo, márgenes y códigos se ven con un clic en la fila.

### Ventas
- **Nombre y marca en todos lados:** la búsqueda, el carrito y el comprobante muestran "NOMBRE · MARCA", y abajo la descripción y el código.
- **El lector y los atajos ya no chocan:** mientras el cursor está en el buscador, las letras son texto ("toalla", "crema", "dino" se escriben enteros). Para usar los atajos E, T, Q, Z, C, D y R, apretá Esc con el buscador vacío: aparece "Atajos activos" debajo de la forma de pago. Cualquier otra letra vuelve al buscador.
- **El lector agrega al primer Enter**, también con códigos con letras (INT-…, Code 128). Si lo tipeado no es un código exacto, se muestra la lista y no se agrega nada solo: se elige con las flechas y Enter, o con un clic.
- **Esc ya no vacía el ticket.** Para vaciarlo está el botón "Vaciar ticket", que pide confirmación.
- Después de tocar un botón (forma de pago, +, −, ✕, cliente, tickets) o de cerrar una ventana, el cursor vuelve solo al buscador. Enter sobre un botón ya no lo dispara sin querer.
- **Nunca se cobra dos veces:** si se corta internet o se cierra la app justo al cobrar, al volver el sistema se da cuenta de que esa venta ya se registró, cierra el ticket y avisa.
- Mientras se está guardando un cobro no se puede cerrar la ventana. F5 y Ctrl+R ya no recargan la app.

### Comprobantes y devoluciones
- El comprobante (en pantalla, PDF e imagen) muestra el nombre y la marca completos, sin cortar. Si después se cambia el nombre de un producto, los comprobantes y devoluciones viejos siguen mostrando el de ese momento.
- Devolución / Cambio: el buscador del cambio funciona igual que el de Ventas, Esc cierra la ventana (pregunta antes si hay datos cargados).
- Stock bajo, defectuosos y actualizar precios también muestran nombre y marca.

## 0.4.2 — octubre 2026

### Proveedores
- **Observaciones del proveedor:** en el formulario de proveedor (nuevo y editar) hay un campo "Observaciones" para anotar lo que haga falta recordar de ese proveedor. Es opcional.
- Las observaciones aparecen en un recuadro amarillo al elegir el proveedor en "Nueva factura de compra" y en la cuenta corriente del proveedor, arriba de los saldos. Si no tiene observaciones, no se muestra nada.

## 0.4.1 — octubre 2026

### Carga inicial de inventario
- **Buscar con el lector en "Inventario total":** se escanea el código con el lector (o con el botón de escaneo) y el producto aparece al instante. La próxima lectura reemplaza a la anterior, y el código se encuentra aunque el lector lo mande con o sin el 0 adelante.

## 0.4.0 — octubre 2026

### Carga inicial de inventario
- **Nueva pantalla "Carga inicial"** (menú Gestión), visible solo mientras un administrador tiene abierta la etapa desde Virikyna Gestión. Sirve para cargar el inventario existente del local: código, nombre, marca, descripción, precio de venta y cantidad, sin proveedor ni costo.
- **Varias personas a la vez:** cada una arma su lista y la confirma con "Finalizar mi carga". Al escanear o tipear un código se avisa si el producto ya existe o si otra persona ya lo cargó ("Ya cargado por…"), con las opciones "Usar sus datos y sumar" o "Usar mis datos".
- Funciona con el lector de códigos: Enter pasa al siguiente campo y guarda la fila. Si un producto no tiene código, el sistema genera uno para etiquetar.
- **Sin conexión no se pierde nada:** la fila queda "No guardada" con un botón Reintentar, y reintentar nunca suma la cantidad dos veces.
- **Inventario total:** lista de todos los productos con su stock en el local, con buscador y edición de nombre, marca, descripción, precio y cantidad.
- Cuando el administrador cierra la etapa, la pantalla desaparece del menú.

### Precios e Inventario
- **Productos con precio manual:** los productos cargados en la carga inicial no tienen costo y tienen un precio de venta fijo. En el formulario de producto se ve como "Precio de venta (manual)" y se puede editar. La primera factura de compra le pone costo y el precio pasa a calcularse solo.
- En las listas, un costo vacío se muestra como "—" y los precios manuales tienen la marca "manual".
- **Factura de compra:** al cargar un producto con precio manual se avisa "Precio manual $X → calculado $Y".
- **Actualizar precios:** a los productos con precio manual el porcentaje se les aplica sobre el precio, con el mismo redondeo.

## 0.3.0 — octubre 2026

### Proveedores
- **Cuenta corriente de cada proveedor.** En la pestaña Proveedores, al tocar un proveedor se abre su cuenta: saldo, comprobantes pendientes, crédito disponible de notas de crédito y último pago. Los comprobantes se ven separados en Pendientes, Pagados y Todos, y hay una pestaña con todos los pagos. Se puede filtrar por tipo, fechas y número.
- **Pagar varias facturas juntas.** Desde la cuenta corriente se tildan las facturas (y, si hay, notas de crédito) y se pagan en un solo paso. Antes de confirmar se ve cómo se reparte el pago entre las facturas. Si no se elige ninguna, el pago se aplica a las más viejas primero.
- **Las notas de crédito ahora restan** del saldo del proveedor y se pueden usar para cancelar facturas.
- **Detalle de factura más completo:** muestra todos los pagos y créditos que se le aplicaron, también los de pagos que cubrieron varias facturas a la vez. Muestra el estado (Pendiente, Parcial, Pagada, Anulada).
- **Facturas anuladas** aparecen tachadas y con la etiqueta "Anulada". En su detalle ya no se ofrece registrar un pago.
- **Copiar una factura.** Se puede cargar una factura nueva partiendo de otra (también de una anulada o de otro proveedor): desde "Copiar" en la lista, en el detalle o en la cuenta corriente, o con "Copiar desde…" dentro del formulario. Número y fecha quedan vacíos para completarlos.
- **Aviso de comprobante repetido:** al cargar, si ya existe un comprobante del mismo proveedor con el mismo número, el sistema avisa (no impide guardar).
- **Producto inactivo en una factura:** si un ítem tiene un producto que hoy está inactivo, se avisa y hay que elegir "Usarlo igual" u otro producto antes de guardar.
- **Nuevo tipo de comprobante: Presupuesto.** Se carga igual que un remito: suma stock, actualiza costo y suma deuda.
- **El costo del producto se actualiza con la factura de compra**, y el formulario muestra en cada ítem cómo cambia el precio de venta.

### Precios e Inventario
- **Redondeo del precio de venta:** hasta $500 se redondea a la centena; hasta $10.000, a múltiplos de $500; desde $10.000, a múltiplos de $1.000.
- En el formulario de producto se ve el precio calculado y el redondeado, y se usa el IVA propio de cada producto.
- **Actualizar precios:** ahora muestra una vista previa producto por producto antes de aplicar los cambios, y se puede usar con teclado.

### Caja y Egresos
- Los pagos a proveedores hechos desde Virikyna Gestión ya **no se descuentan del cierre de caja** del local; solo cuentan los que salen de la caja.
- El cierre del día y las fechas usan siempre la hora de Argentina, sin importar la configuración de la PC.

### Facturación
- La **nota que se cargó en la venta** ahora se ve en el detalle del comprobante. Es interna: no sale en el PDF, en la imagen ni en el mensaje que se envía al cliente.

### Dashboard
- El aviso de stock bajo es más rápido y muestra los productos por debajo del mínimo.
