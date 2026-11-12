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

### 1.1 Comprobante interno (dueñas y empleados, docs/68)

Venta a **cuenta corriente** de un cliente marcado como **interno**. Paralelo al estado fiscal: nunca pasa a Factura C.

```
Venta a cta. cte. ──▶ A revisar ──▶ Finalizado ──▶ (Reabierto) ──▶ A revisar ──▶ Finalizado …
   (Local)           (pendiente)    (finalizado)     (Admin, motivo)
                   Admin edita % por producto
```

| Estado (`ventas.estado_interno`) | Qué pasa | Quién | Reversible |
|---|---|---|---|
| A revisar (`pendiente`) | Suma al saldo del cliente. La dueña aplica descuento por producto (solo baja) viendo el margen. Guardar no la cierra | Cajero la registra · Admin edita | Sí: se edita las veces que haga falta; Anular venta como cualquier otra |
| Finalizado (`finalizado`) | Cerrado sin cobro ni caja: se descuenta del sueldo fuera del sistema. Sale del saldo y entra al total del mes de finalización | Admin | Sí: Reabrir (Admin, motivo obligatorio, queda auditado) |

**Reglas clave:**
- Nunca lleva Factura C (bloqueado en la base y oculto en Facturación).
- Un comprobante finalizado no se edita ni se devuelve: hay que reabrirlo primero.
- Cada edición, finalización y reapertura sube la versión del comprobante: si dos personas lo editan a la vez, la segunda recibe el aviso y vuelve a ver la versión actual.
- El stock y la fecha de la venta nunca cambian al editar.

### 1.2 Devolución / Cambio (docs/24, docs/74)

Documento nuevo sobre **1 a 3 tickets** ya cobrados. Nunca modifica las ventas originales.

```
Tickets (1–3) ──▶ Qué se devuelve (por línea) + qué se lleva ──▶ Diferencia ──▶ Devolución activa ──▶ (Anulada)
   (Local)                 (Local)                                 │                                  (Admin, motivo)
                                                                   ├─ paga el cliente → cobro (caja)
                                                                   ├─ saldado justo  → sin movimiento
                                                                   ├─ a favor → reintegro (caja) o queda a favor (nota, sin caja)
                                                                   └─ ticket a cta. cte. (solo) → a la cuenta del cliente
```

| Estado (`devoluciones.estado`) | Qué pasa | Quién | Reversible |
|---|---|---|---|
| Activa | Reingresa al stock lo devuelto sano (lo defectuoso no), descuenta lo que se lleva, y si hubo cobro o reintegro impacta la caja del día | Cajero / Admin | Sí: Anular |
| Anulada | Revierte el stock. Sale de los cierres que todavía no se emitieron (un cierre ya hecho no se reescribe) | Admin, motivo obligatorio | No |

**Reglas clave:**
- Todo o nada: si un ticket o una cantidad no pasa, no se guarda nada.
- Un ticket con una devolución activa no se puede anular: primero se anula la devolución.
- "Queda a favor" es solo un registro con nota: no mueve la caja ni la venta neta; el cierre lo muestra como dato informativo.

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
