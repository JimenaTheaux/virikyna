# Diagnóstico: ENTER en formularios y formato de importes

Fecha: 2026-11-05 · Alcance: Virikyna Gestión y Local · **Solo diagnóstico, sin cambios de código.**

Fuentes: código del repo (rama `lote-oct-2026`) y una prueba en Chromium con locale `es-AR` (el mismo motor que el navegador de Gestión y que WebView2, el de Local). El script quedó en el scratchpad de la sesión (`coma_number.cjs`).

---

## A) ENTER en el pago a proveedores

### A.1 Componentes y cómo se dispara el envío

Hay **dos formularios** de pago en Gestión, más uno propio de Local:

| Formulario | Desde dónde se abre | Archivo | RPC |
|---|---|---|---|
| `PagarProveedorModal` (compartido) | Cuenta corriente del proveedor, en Gestión y Local | [packages/shared/src/components/PagarProveedorModal.tsx](../packages/shared/src/components/PagarProveedorModal.tsx) | Gestión: `registrar_pago_proveedor_v3` (varios medios). Local: `_v2` (un medio) |
| `RegistrarPagoProveedorModal` (Gestión) | Detalle de una factura de compra | [apps/virikyna-gestion/src/pages/Proveedores/RegistrarPagoProveedorModal.tsx](../apps/virikyna-gestion/src/pages/Proveedores/RegistrarPagoProveedorModal.tsx) | `registrar_pago_proveedor_v3` |
| `RegistrarPagoProveedorModal` (Local) | Detalle de una factura de compra en Local | [apps/virikyna-local/src/pages/Proveedores/RegistrarPagoProveedorModal.tsx](../apps/virikyna-local/src/pages/Proveedores/RegistrarPagoProveedorModal.tsx) | `registrar_pago_proveedor` (v1, un medio) |

Mecanismo en los dos de Gestión:
- `<form id={formId} onSubmit={handleSubmit}>` ([PagarProveedorModal.tsx:222-227](../packages/shared/src/components/PagarProveedorModal.tsx#L222-L227)).
- El botón "Registrar pago" está en el pie del modal, **fuera del `<form>`**, pero asociado con `type="submit" form={formId}` ([:211-218](../packages/shared/src/components/PagarProveedorModal.tsx#L211-L218); [RegistrarPagoProveedorModal.tsx:122-129](../apps/virikyna-gestion/src/pages/Proveedores/RegistrarPagoProveedorModal.tsx#L122-L129)).
- No hay ningún `onKeyDown` que frene Enter. HTML aplica el **envío implícito**: Enter en cualquier `<input>` de texto, número o fecha envía el formulario si su botón submit está habilitado. Lo verifiqué en Chromium: Enter en un input número y en uno fecha → 1 envío. Enter en un `<select>` → 0 envíos. El botón asociado por `form=` cuenta igual que uno de adentro.

**Por qué pasa siempre en el primer campo.** El modal abre con:
- el foco en "Total del pago" (`data-autofocus`);
- el monto **precargado** con el saldo a pagar ([:68](../packages/shared/src/components/PagarProveedorModal.tsx#L68));
- un medio "Efectivo" por el total que **sigue al total** ([MediosPagoEditor.tsx:20-34](../packages/shared/src/components/MediosPagoEditor.tsx#L20-L34)).

Los medios "cierran" desde el primer momento, así que el botón está habilitado ([:89-90](../packages/shared/src/components/PagarProveedorModal.tsx#L89-L90), [:214](../packages/shared/src/components/PagarProveedorModal.tsx#L214)). Un Enter para "pasar a Fecha" registra en el acto un pago **en efectivo por el total**. `handleSubmit` valida, pero un pago en efectivo por el total es válido.

**Los datos lo confirman.** En los pagos de GUTIERREZ (28/10) y TOYCO (02/11) está exactamente ese patrón: pago en efectivo por el total → reversión → pago mixto por el mismo monto, el mismo día (ver [DIAGNOSTICO_SALDOS_INICIALES.md](DIAGNOSTICO_SALDOS_INICIALES.md)).

### A.2 Orden de campos y foco

`PagarProveedorModal` desde Gestión, con varios medios (orden del DOM = orden de Tab):

1. ✕ cerrar (encabezado; el foco inicial no cae acá)
2. **Total del pago**: `number`, autofoco, precargado
3. **Fecha del pago**: `date`
4. Botones "+ Agregar medio" y "+ Generar cheques" (`type="button"`: Enter hace clic, no envía)
5. Por cada medio: **Medio** (`select`) → **Monto** (`number`) → ✕ Quitar (botón). Si es cheque o eCheq, además: **N° de cheque** → **Banco** → **Fecha de pago** (`date`)
6. **Nota (opcional)**: texto. **Es el último campo**
7. Tabla "Cómo se reparte" (sin campos)
8. Pie: Cancelar → **Registrar pago**

Con 6 o más medios, la lista tiene alto máximo (`max-h-[22rem]`) y scrollea sola. Cada medio suma de 2 a 5 campos, todos con el mismo riesgo: Enter en el Monto o en el N° de cheque del medio 3 envía el pago si los medios ya suman el total.

El panel **"Generar cheques"** es la única parte protegida: su `onKeyDown` convierte Enter en "Agregar cheques" y no envía el pago ([MediosPagoEditor.tsx:248-256](../packages/shared/src/components/MediosPagoEditor.tsx#L248-L256)). Sus campos: Tipo, Cantidad, Cada (días), Desde, radio Total/Cada uno, Monto, Banco, N° del primero.

Hay un freno parcial: si los medios **no** suman el total, el botón queda deshabilitado y Enter no envía (no hay envío implícito con el botón deshabilitado). Por eso el riesgo es máximo justo cuando todo "cierra", por ejemplo en el estado inicial.

`RegistrarPagoProveedorModal` (Gestión) tiene el mismo orden, sin el aviso de reparto: Total (precargado con el saldo de la factura) → Fecha → medios → Nota.

`PagarProveedorModal` desde Local (un solo medio): Monto → Fecha → Forma de pago (`select`) → si es cheque: Nro. de cheque → Fecha de salida → Fecha de vencimiento → Nota.

### A.3 Diálogos de confirmación reutilizables

- **No hay shadcn ni Radix** en el repo, así que no existe `AlertDialog`.
- Existe **`ConfirmDialog`** propio ([packages/shared/src/components/ConfirmDialog.tsx](../packages/shared/src/components/ConfirmDialog.tsx)), montado sobre `Modal`:
  - el foco arranca en Cancelar y Esc cancela;
  - recibe `title`, `mensaje` (multilínea), `confirmLabel`, `cancelLabel` y `confirmando`;
  - el botón de confirmar está **estilado como destructivo** (borde rojo).
- **Ya se usa como confirmación previa a guardar**:
  - "Pago de contado" en la carga de factura (`confirmLabel="Confirmar y guardar"`, `cancelLabel="Volver"`, [CargarFacturaCompraModal.tsx:1008-1023](../packages/shared/src/components/CargarFacturaCompraModal.tsx#L1008-L1023));
  - `ConfirmarFacturaC` antes de emitir.
- También está `DialogoCierreBorrador` en [Modal.tsx:67-116](../packages/shared/src/components/Modal.tsx#L67-L116), que es de cierre, no de confirmación de guardado.
- Hay **un precedente de "Enter no guarda"**: `CargarFacturaCompraModal` corta Enter en todo `<input>` desde el `onKeyDown` del form ([:680-689](../packages/shared/src/components/CargarFacturaCompraModal.tsx#L680-L689)). Lo agregaron por el lector de código de barras. Ningún formulario implementa "Enter = Tab".

### A.4 Otros formularios con el mismo riesgo

Todos son `<form onSubmit>` con botón submit y sin freno de Enter. "Precargado" significa que el campo con foco ya trae un valor válido, así que un Enter inmediato guarda.

**Mueven plata o stock (prioridad):**

| App | Formulario | Archivo | Qué crea un Enter apurado |
|---|---|---|---|
| Gestión + Local | Pago a proveedor (cta. cte.) | `packages/shared/.../PagarProveedorModal.tsx` | Pago en efectivo por el total (precargado) |
| Gestión | Pago desde la factura | `apps/virikyna-gestion/.../Proveedores/RegistrarPagoProveedorModal.tsx` | Ídem (precargado con el saldo) |
| Local | Pago desde la factura | `apps/virikyna-local/.../Proveedores/RegistrarPagoProveedorModal.tsx` | Pago con la forma de pago por defecto |
| Gestión + Local | Cobro a cliente | `.../Clientes/RegistrarPagoClienteModal.tsx` (las dos apps) | Enter en Monto (primer campo, autofoco) → cobro con la forma por defecto y "Cuenta general" |
| Gestión | Egreso general | `apps/virikyna-gestion/src/pages/Egresos/RegistrarEgresoTab.tsx` | Egreso con la forma o categoría por defecto |
| Gestión | Ingreso/egreso manual y transferencia entre cuentas | `apps/virikyna-gestion/src/pages/CajaGestion/MovimientosManualesTab.tsx` (2 forms) | Movimiento de caja |
| Gestión | Editar movimiento | `.../CajaGestion/EditarMovimientoModal.tsx` | Anula y recrea el movimiento |
| Local | Egreso de turno | `apps/virikyna-local/src/pages/CierreCaja/RegistrarEgresoModal.tsx` | Egreso de caja (Monto es el primer campo, con autofoco) |
| Local | Retiro de efectivo | `.../CierreCaja/RegistrarRetiroModal.tsx` | Retiro |
| Local | Cierre Z | `.../CierreCaja/ConfirmarCierreZModal.tsx` | Cierre Z (lo mitiga `MontoLeido`, que muestra el monto leído) |
| Local | Pago combinado / ajuste % en venta | `.../Ventas/PagoCombinadoModal.tsx`, `AjustePorcentajeModal.tsx` | Aplica al ticket (no guarda la venta) |
| Gestión + Local | Ajuste de stock | `.../Inventario/AjustarStockModal.tsx`, `AjustarStockSheet.tsx` | Movimiento de stock |
| Shared | Editar factura de compra | `packages/shared/src/components/EditarFacturaCompraModal.tsx` | Guarda la edición |
| Shared | Anular factura de compra | `.../AnularFacturaCompraModal.tsx` | Anula (solo pide el motivo; Enter después del motivo = confirmar) |
| Shared | Marcar IVA | `.../MarcarIvaModal.tsx` | Tiene un ConfirmDialog previo |

**Menor riesgo:** altas y ediciones de producto, proveedor y cliente, notas, usuarios, blanqueo de contraseña.

**Protegidos:**
- Carga de factura de compra (Enter bloqueado).
- Carga inicial de saldos (no es un `<form>`, se guarda con `onClick`).
- Actualizar precios: Enter genera la vista previa a propósito y aplicar es un segundo paso.
- Panel Generar cheques.

---

## B) Formato de importes

### B.1 Input de moneda compartido

**No existe.** No hay `MontoInput`, `CurrencyInput` ni nada parecido. Cada formulario usa un `<input type="number" step="0.01">` crudo con `inputClass` ([FormField.tsx](../packages/shared/src/components/FormField.tsx)).

Lo más cercano es **`MontoLeido`** ([apps/virikyna-local/src/components/MontoLeido.tsx](../apps/virikyna-local/src/components/MontoLeido.tsx)). Muestra debajo del campo "Se va a registrar: $ X" con `formatCurrency`. Se creó por el Cierre Z del 20/10 (632.250 se leyó como 632,25). Solo se usa en Local, en `AbrirCajaCard` y `ConfirmarCierreZModal`.

### B.2 Inputs de importe

Todos son `type="number"`. Todos guardan el **texto** del campo en el estado (`useState<string>`) y lo convierten con **`Number(str)`** al validar o enviar. No hay `parseFloat` ni un parser propio.

| App | Archivo | Campo(s) | `min` |
|---|---|---|---|
| Shared | `PagarProveedorModal.tsx:264` | Total del pago | 0 |
| Shared | `MediosPagoEditor.tsx:154` | Monto de cada medio | 0 |
| Shared | `MediosPagoEditor.tsx:290` | Generar cheques: total / monto de cada uno | 0 |
| Shared | `ItemFacturaRow.tsx:163, 283` | Precio unitario sin IVA (factura de compra); también cantidad y % de descuento | 0 |
| Shared | `cargaInicial/MiCarga.tsx:693, 751` | Precio (carga inicial de inventario) | 0 |
| Gestión | `Proveedores/RegistrarPagoProveedorModal.tsx:155` | Total del pago | 0 |
| Gestión | `Clientes/RegistrarPagoClienteModal.tsx:76` | Monto del cobro | 0 |
| Gestión | `Egresos/RegistrarEgresoTab.tsx:93` | Monto | — |
| Gestión | `CajaGestion/MovimientosManualesTab.tsx:195, 242` | Monto del movimiento, monto de la transferencia | — |
| Gestión | `CajaGestion/EditarMovimientoModal.tsx:83` | Monto | — |
| Gestión | `CajaGestion/CargaInicialTab.tsx:187, 213, 242` | Saldo por cuenta, proveedor y cliente | — |
| Gestión | `Inventario/ProductoFormModal.tsx:422, 468` | Costo, precio manual | 0 |
| Local | `Proveedores/RegistrarPagoProveedorModal.tsx:120` | Monto | — |
| Local | `Clientes/RegistrarPagoClienteModal.tsx:76` | Monto | 0 |
| Local | `CierreCaja/RegistrarEgresoModal.tsx:198` | Monto | — |
| Local | `CierreCaja/RegistrarRetiroModal.tsx:95` | Importe | — |
| Local | `CierreCaja/ConfirmarCierreZModal.tsx:55` | Efectivo contado (+ `MontoLeido`) | — |
| Local | `Dashboard/AbrirCajaCard.tsx:136` | Monto real en caja (+ `MontoLeido`) | — |
| Local | `VentasPage.tsx:731` | Precio cobrado (producto sin precio) | 0 |
| Local | `Ventas/PagoCombinadoModal.tsx:97, 119` | Monto 1 y monto 2 | 0 |
| Local | `Inventario/ProductoFormSheet.tsx:444, 498` | Costo, precio manual | 0 |

No son importes, pero usan el mismo patrón `number`: márgenes y porcentajes (`ProveedorFormModal`, `ProductoForm*`, `AjustePorcentajeModal`, `ActualizarPreciosModal`), cantidades (carrito, ajuste de stock, devoluciones, ítems de factura).

### B.3 Helper de formato

- **`formatCurrency(n)`** en [packages/shared/lib/format.ts:1-3](../packages/shared/lib/format.ts#L1-L3): `Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' })` → `$ 4.500,40` (con espacio duro). Es exactamente el formato que pide la dueña. Hay variantes: `formatCurrencyOpcional` (null → "—"), `formatCurrencyCompact` ("$12,3 mil") y `formatAjuste` (con signo).
- Se usa en casi toda la **visualización**: listados, KPIs, previsualizaciones, `ResumenMedios`, comprobantes.
- Excepciones:
  - `confirmacionFacturaC.ts:19` tiene su propia instancia de Intl (mismo resultado);
  - `cargaInicial.ts:421` y `comprobanteLayout.ts:40` formatean números sin símbolo (cantidades);
  - **`validarMedios`** arma su mensaje con `toFixed(2)` ([mediosPago.ts:65-67](../packages/shared/lib/mediosPago.ts#L65-L67)) y la persona ve "Los medios suman 4500.40 y el pago es de 4600.00". Es el único texto de importes fuera de formato.
- **Ningún input** usa el helper: el formato existe solo para leer, nunca para escribir.

### B.4 Cómo se guarda el valor y qué se rompe si cambia el input

- **En el formulario:** string crudo del input (`"4500.40"`). Los valores precargados se arman con `String(n)` o `toFixed(2)`:
  - `montoTexto` en PagarProveedorModal:38;
  - `String(saldoPendiente)` en RegistrarPagoProveedorModal:43;
  - `falta.toFixed(2)` y `generarCheques` en MediosPagoEditor/mediosPago.
- **En la lógica:** `Number(str)` en cada render. Los medios de pago suman en **centavos** (`Math.round(n*100)`, [mediosPago.ts:26-42](../packages/shared/lib/mediosPago.ts#L26-L42)) para que los cheques repartidos cierren exacto.
- **Al RPC:** `number` de JS en el JSON; algunos se redondean antes a 2 decimales (`payloadMedios`).
- **En la base:** `NUMERIC(12,2)`. El RPC revalida.

Riesgos si el campo pasa a mostrar `$ 4.500,40`:

1. **`Number("$ 4.500,40")` es `NaN`.** Hoy el texto del input alimenta en vivo muchas cosas: el total del pago (`montoNum`), `diferenciaMedios`, `simularRepartoPago` (vista previa), el botón habilitado o deshabilitado, `useMediosPago` (copia el **texto** del total al medio 1), "+ Agregar medio" (propone lo que falta), `MontoLeido` y `PagoCombinadoModal` (calcula el monto 2). Si el estado pasa a guardar texto formateado, todo eso se rompe en silencio: NaN → "Ingresá un monto válido", o una vista previa vacía.
2. **`type="number"` no acepta `$` ni separadores de miles.** Mostrar el formato obliga a pasar a `type="text"`, y eso pierde la validación nativa que hoy frena algunos errores sin que nadie lo haya diseñado:
   - `min="0"` bloquea negativos;
   - `step="0.01"` bloquea `4.500,40` (ver B.5);
   - el teclado numérico en táctil (habría que poner `inputMode="decimal"`).
3. **Ambigüedad del punto.** El ejemplo de la dueña (`4500.40` → `$ 4.500,40`) usa el punto como **decimal**. El incidente del Cierre Z (`632.250` = seiscientos treinta y dos mil) lo usa como **miles**. Hoy el sistema siempre lo trata como decimal. Cualquier cambio de criterio cambia el resultado de lo que ya tipean las personas.
4. **Muchos puntos de contacto.** Son unos 25 campos de importe en 3 apps, más Inventario (celular), que comparte `ItemFacturaRow` y `MiCarga`. Hay dos copias casi iguales de varios formularios entre Gestión y Local.
5. **Tests.** `tests/mediosPago.test.ts` prueba la lógica con strings `"1234.56"`. Si cambia el formato del string, esos tests y los precargados con `toFixed` tienen que acompañar el cambio.

### B.5 ¿Se puede escribir coma decimal hoy?

Sí. Probado en Chromium `es-AR`, tipeando en un `<input type="number" step="0.01" min="0">` como el de los formularios:

| Lo que tipea la persona | `value` del input | Lo que lee la app (`Number`) | ¿El navegador bloquea el envío? |
|---|---|---|---|
| `4500.40` | `4500.40` | 4500,40 ✅ | no |
| `4500,40` | `4500.40` | 4500,40 ✅ (convierte la coma en punto) | no |
| `1,5` | `1.5` | 1,5 ✅ | no |
| `4.500,40` | `4.50040` | **4,5004** | **sí**: no respeta `step` (aviso nativo "valor no válido") |
| `4.500` | `4.500` | **4,50** ❌ | **no**: se guarda $ 4,50 |
| `632.250` | `632.250` | **632,25** ❌ | **no** (es el caso del Cierre Z) |
| `4500,4,0` | `4500.40` | 4500,40 | no (descarta la segunda coma) |
| `-10` | `-10` | −10 | sí, solo donde hay `min="0"` |
| `1e3` | `1e3` | 1000 | no |

Conclusión: la coma decimal ya funciona, porque Chromium la normaliza. **El peligro real es el punto como separador de miles**. `4.500` o `632.250` se guardan 1000 veces más chicos, sin error. Solo se nota en Local en los dos campos que tienen `MontoLeido`. En Gestión no hay ninguna señal hasta la vista previa, y solo en el pago a proveedor.

Una advertencia: la normalización de la coma depende del navegador y del idioma. Firefox se comporta distinto. Local corre en WebView2 (Chromium) y Gestión se usa en navegador; no relevé qué navegador usa la dueña.

---

## Riesgos (resumen)

1. **Pagos y cobros duplicados por Enter.** Ya pasó (GUTIERREZ, TOYCO). Cada error deja un pago, una reversión y un pago nuevo, más movimientos de cuenta y auditoría que no se borran. El cobro a clientes y los egresos tienen el mismo riesgo y más directo: Monto es el primer campo y no hay ningún otro paso.
2. **Montos 1000 veces menores sin aviso** si se tipea el punto como miles (`4.500`). Hoy solo lo mitiga `MontoLeido` en 2 campos de Local.
3. **Cambiar el input de importe toca la lógica**, no solo la vista: el texto del campo se usa en cálculos en vivo en al menos 5 componentes, y pasar a `type="text"` elimina las validaciones nativas que hoy frenan negativos y `4.500,40`.
4. **El criterio del punto es contradictorio** entre el pedido de la dueña (punto decimal) y el uso real que causó el error del Cierre Z (punto de miles). Hay que definirlo con ella antes de implementar.
5. **`ConfirmDialog` sirve, pero está estilado como acción destructiva.** Usarlo para "Confirmar pago" mostraría la acción principal en rojo.
6. **Duplicación Gestión/Local.** Los formularios de cobro, pago desde factura y egreso tienen copias separadas: un arreglo en una app no llega a la otra.
