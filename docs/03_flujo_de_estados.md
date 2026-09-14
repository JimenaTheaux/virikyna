# 03 — Flujo de Estados — Virikyna POS

Versión en markdown de los 4 ciclos de vida ya validados con la clienta (versión interactiva: `virikyna-como-funciona.html`, incluida en este mismo entregable). Esta es la referencia técnica para desarrollo; el HTML es la versión para mostrarle a la dueña.

---

## 1. Ciclo de vida de una Venta / Comprobante

```
Venta en curso ──▶ Cobro ──▶ Comprobante X ──▶ Selección para facturar ──▶ Emisión Factura C ──▶ Historial
  (Ventas)        (Ventas)      (Ventas)           (Facturación)             (Facturación)      (Facturación)
```

| Estado | Qué pasa | Quién | Reversible |
|---|---|---|---|
| Venta en curso | Se arma el carrito, se elige cliente | Cajero | Sí (cancelar, sin dejar rastro — todavía no es un registro) |
| Cobrado → Comprobante X | Se registra la venta y el pago (`estado = sin_facturar`) | Cajero | Sí, si aún no tiene Factura C (anular venta) |
| Facturado → Factura C | Se emitió con CAE de ARCA (`estado = facturado`) | Cajero/Admin | **No** — requiere Nota de Crédito (fuera de alcance Fase 1) |

**Reglas clave:**
- Cobrar **nunca** dispara la Factura C automáticamente — son dos pasos separados, a propósito.
- Un Comprobante X = una Factura C. Nunca se agrupan varios comprobantes en una sola factura, aunque se seleccionen juntos para facturar.
- Sin impresora fiscal: si no hay internet al momento de facturar, la emisión queda pendiente — la venta ya cobrada no se ve afectada.
- El Comprobante X se puede descargar en PDF y enviar por mail/WhatsApp en cualquier momento, esté facturado o no.

---

## 2. Ciclo de vida de un Producto

```
Alta ──▶ Activo ──▶ (Ajuste manual, si hace falta) ──▶ Inactivo ──▶ Reactivación
(Inventario) (Ventas/Inventario)   (Inventario, solo Admin)      (Inventario)      (Inventario)
```

| Estado | Qué pasa | Quién | Reversible |
|---|---|---|---|
| Alta | Se carga por código de barras o manual | Admin/Cajero | Eliminación solo si es error de carga reciente |
| Activo | Aparece en Ventas, stock se mueve automático | — | — |
| Ajuste manual | Corrección de stock por rotura/pérdida/conteo, motivo obligatorio | **Solo Admin** | Sí, mediante contra-asiento (nunca se pisa el original) |
| Inactivo (baja lógica) | Deja de aparecer en Ventas, conserva historial | Admin/Cajero | Sí, se puede reactivar |

**Nota:** la Eliminación es un camino aparte, no un estado del ciclo normal — solo para corregir un error de carga muy reciente, con confirmación explícita.

---

## 3. Ciclo de vida de un Cierre de Caja

```
Turno en curso ──▶ Cierre X (se repite) ──▶ Cierre Z (una vez por día) ──▶ Caja Gestión ──▶ Validación
   (Ventas)          (Cierre de Caja)           (Cierre de Caja)          (Admin, tablero)   (Admin)
```

| Estado | Qué pasa | Quién | Reversible |
|---|---|---|---|
| Turno en curso | Ventas normales del día | Cajero | — |
| Cierre X | Foto del estado actual, no bloquea, se repite libremente | Admin/Cajero | No aplica (no es un cierre definitivo) |
| Cierre Z | Cierre único del día: totales por medio de pago, egresos, efectivo esperado vs. contado | Admin/Cajero | **No** — solo nota de corrección |
| Validación (Caja Gestión) | La dueña valida el Cierre Z para que impacte en la caja general | **Solo Admin** | No — es el cierre del circuito contable del día |

---

## 4. Ciclo de Auditoría y Reversión (transversal a todo el sistema)

Este no es un ciclo de una entidad — es el mecanismo que envuelve a todos los anteriores.

```
Cualquier acción (alta/edición/eliminación) ──▶ Se registra sola en `auditoria` (trigger, no manual)
                                                          │
                                    ¿Es reversible? ──────┴────── No (venta facturada, Cierre Z validado)
                                          │                              │
                                         Sí                      Queda visible, no accionable
                                          │
                          Admin la revierte desde Virikyna Gestión
                                          │
                      Se crea una ACCIÓN NUEVA (revierte a la original)
                                          │
                        Ambas quedan visibles en el historial, para siempre
```

**Regla de oro:** revertir nunca borra ni edita la fila de auditoría original — siempre es una acción nueva que compensa a la anterior. El historial cuenta la verdad completa, no una versión editada.

Ver tabla completa de qué es reversible y qué no, por tipo de acción, en `04_modulos_y_funciones.md` (módulo 10) y el detalle técnico de implementación en `06_estructura_de_datos.md`.
