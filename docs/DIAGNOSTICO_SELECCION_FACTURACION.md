# Diagnóstico — selección y suma en Facturación

Fecha: 2026-11-06. Pedido de la dueña: tildar y sumar **todas** las ventas (también las facturadas)
y una opción "Seleccionar todo".

> **Estado:** implementado el mismo día (ver sección "Implementación", al final). Lo que sigue es el
> diagnóstico tal como estaba el código antes del cambio.

## 1. Ubicación

| | Gestión | Local |
|---|---|---|
| Archivo | `apps/virikyna-gestion/src/pages/Facturacion/FacturacionTab.tsx` (+ `filtroVentas.ts`) | `apps/virikyna-local/src/pages/Facturacion/FacturacionTab.tsx` |
| Página | tab "Facturación" de `FacturacionPage.tsx` | ruta `/facturacion`, roles **admin y cajero** (`layout/AppShell.tsx`) |
| Carga | react-query | `useEffect` + `cargar()` |
| Buscador | N°, nota o cliente, en cliente; vive en la URL (`?q=`, `?notas=1`) | N° en servidor (ignora los 30 días), cliente en cliente |
| Chip "Con notas" / columna Nota | sí | no |
| Ventas internas (`estado_interno`) | excluidas (docs/68 D5) | **no excluidas** |
| Menú por fila | Ver comprobante | Ver comprobante + Devolución/Cambio |

Son **dos copias distintas**, no un componente compartido ("Ventas del día" sí es compartida).

## 2. Selección (antes del cambio)

- Checkbox solo si `venta.estado === 'sin_facturar' && !idsARevisar.has(venta.id)`.
- Estado: `seleccion: Set<string>` (solo ids).
- `seleccionadas` = tildadas ∩ visibles ∩ sin facturar ∩ no a revisar. Esa **misma lista** era la suma
  y el lote de **Emitir Factura C** (`ConfirmarFacturaC` → `emitirFacturas` → `emitirFacturaCReal`,
  producción, irreversible). No tenía otro uso.

## 3. Suma

`seleccionadas.reduce((acc, v) => acc + v.total, 0)`. `total` = precio cobrado (docs/23): con
descuento, recargo y redondeo manual; no `subtotal` ni `precio_oficial`. Texto
"N seleccionado(s) · $ X", solo con selección.

## 4. Filtros y paginación

- Servidor: Desde/Hasta (sin fechas = últimos 30 días), Estado (Todas/Sin facturar/Facturada), Medio de pago.
- Cliente: buscador (+ chip "Con notas" en Gestión).
- Sin paginación. La API corta en **1000 filas** (max_rows): con rangos amplios la lista y la suma
  podían quedar truncadas sin aviso.
- La selección **no** se vaciaba al cambiar filtros (las ocultas no sumaban, pero reaparecían
  tildadas). Se vaciaba al emitir o al cambiar de tab.

## 5. Acciones sobre la selección

Solo "Emitir Factura C". Barreras: el checkbox y `seleccionadas` (pantalla); la Edge Function
rechaza si ya hay `factura_c`; `reservar_emision_factura_c` rechaza `estado <> 'sin_facturar'`
(docs/66) e internas (docs/68 §17). Mezclar facturadas sin separar listas **no** facturaba dos
veces, pero la confirmación mostraba cantidad y total equivocados y cada facturada volvía como error.

## 6. Otros estados

- **Anuladas:** nunca se listan (`.in('estado', ['sin_facturar', 'facturado'])`).
- **Devueltas:** no hay estado; las devoluciones viven en `devoluciones` y `crear_devolucion` no
  toca `ventas.total` → la suma es **bruta**.
- **Consumo interno:** Gestión las excluye; **Local las listaba** con badge "Sin facturar" y
  checkbox (sumaban; al emitir, el servidor rechazaba). Bug previo: faltaba el filtro de docs/68 D5.
- **Cta. cte.:** `forma_pago = 'cuenta_corriente'` aparece y suma su `total` aunque no esté cobrada.

## 7. Cruces con otras sesiones

Los cambios ajenos sin commitear (`packages/shared/index.ts`, `docs/06`, `MontoInput`/`parseMonto`,
formularios de caja/egresos/proveedores) no tocan Facturación. Cruce indirecto: el trabajo de
"formato de importes" podría cambiar `formatCurrency`.

## Riesgos detectados

1. Selección para sumar = lote de Factura C (lo más delicado).
2. Tope de 1000 filas silencioso.
3. Ventas internas en Local.
4. Selección que sobrevive a los filtros.
5. Dos copias con diferencias.

## Preguntas que quedaron para la dueña

1. ¿El total es lo cobrado o lo cobrado menos devoluciones? (Se implementó: lo cobrado, bruto.)
2. ¿Las ventas a cuenta corriente suman igual que las cobradas? (Se implementó: sí, suman.)

## Implementación (2026-11-06)

- Lógica en `packages/shared/lib/seleccionFacturacion.ts` (`resumenSeleccion`, `alternarTodas`,
  tests en `packages/shared/tests/seleccionFacturacion.test.ts`) y piezas de UI en
  `packages/shared/src/components/SeleccionFacturacion.tsx` (checkbox tri-estado, resumen con
  desglose y aviso del lote, aviso de tope). Se importan por ruta, sin pasar por `index.ts`.
- **Lo que sumo:** checkbox en toda fila visible (sin facturar, facturada, a revisar). Total =
  suma de `total`; desglose "Sin facturar / Facturadas" si hay mezcla.
- **Lo que facturo:** `paraEmitir` = sumadas ∩ `sin_facturar` ∩ no a revisar ∩ no interna. Botón
  "Emitir Factura C (N)"; `ConfirmarFacturaC` recibe solo esa lista. Aviso "Se emiten solo las N sin
  facturar." bajo el botón (al lado no entraba sin empujar los filtros a otra línea).
  `emitirFacturas`, Edge Function y RPCs sin cambios.
- "Seleccionar todo" en el encabezado, tri-estado, sobre las filas visibles.
- Cualquier cambio de filtro, buscador o chip vacía la selección; también al emitir.
- Consultas con `.limit(1000)` y aviso "Se muestran las primeras 1000 ventas…" al llegar al tope.
- Local excluye ventas internas (`.is('estado_interno', null)`), igual que Gestión.
