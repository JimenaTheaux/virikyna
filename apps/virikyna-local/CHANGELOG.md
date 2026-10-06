# Novedades de Virikyna Local

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
