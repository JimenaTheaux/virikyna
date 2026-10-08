# Novedades de Virikyna Local

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
