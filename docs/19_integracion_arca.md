# 19 — Integración real con ARCA (Facturación Electrónica)

Reemplaza el mock de `emitir_factura_c` mencionado en `07_guia_desarrollo_iterativo.md`
FASE 4.

> **⚠️ Incidente 2026-10-26 (docs/59).** Hasta esta fecha los botones de emitir seguían en
> homologación: las 43 Factura C del 19/10 al 26/10 (ventas N° 17 a 198, todas a consumidor
> final) tienen CAE de homologación, **sin validez fiscal**, y no figuran en ARCA. Desde docs/59
> los botones emiten en **producción** (también los cajeros), `facturas_c.ambiente` dice en qué
> ambiente se emitió cada una, y `scripts/reemitir-facturas-c.ts` las re-emite en producción.
> Detalle completo, lo pendiente (condición frente al IVA, comprobante impreso) y cómo verificar:
> **`docs/60_incidente_factura_c_homologacion.md`**.

## 1. Arquitectura

- **Edge Function:** `supabase/functions/arca-emitir-factura/index.ts`. Solo habla con
  ARCA (WSFEv1) — nunca toca `facturas_c` ni el estado de la venta. Eso lo hace el RPC
  `emitir_factura_c` (`06_estructura_de_datos.md`), que asume que el CAE ya se consiguió.
- **SDK:** `@aledj02/afip.js` (fork de `@afipsdk/afip.js` v0.x), no la versión actual de
  `@afipsdk/afip.js` en npm (1.x), que ya no habla directo con ARCA — proxea todo a través
  del servicio cloud de afipsdk.com. `@aledj02/afip.js` acepta cert/key como texto (no como
  paths de archivo) y no cachea el TA de WSAA en disco, lo que encaja con el runtime de
  Edge Functions (sin filesystem persistente entre invocaciones).
- **Bug parcheado en el código (no en el paquete):** `@aledj02/afip.js@0.8.2` nunca invoca
  `Authorization.getTokenAuth()` antes de armar un request de `ElectronicBilling` — se
  parchea en `crearAfip()` reusando el resto de su lógica de armado/parseo SOAP.
- **Caché del TA de WSAA:** tabla `arca_wsaa_tokens` (columnas `servicio`, `cuit`,
  `ambiente`, `token`, `sign`, `expiration_time`). ARCA rechaza pedir un TA nuevo mientras
  exista uno vigente para el mismo servicio+CUIT+ambiente ("ns1:coe.alreadyAuthenticated",
  dura ~12hs) — sin esta caché, cada invocación fría de la Edge Function chocaría con el TA
  de la invocación anterior. Exclusiva del backend (RLS sin policies, solo `service_role`).
- **Bug de parseo conocido:** la librería usa `attrkey: 'header'` en su parser xml2js
  (pensado para atributos XML), que choca de nombre con el elemento `<header>` real de la
  respuesta de WSAA. Cuando `expirationTime` no se puede parsear, se usa un valor de
  respaldo (ahora + 12hs, que es la validez real de un TA de WSAA) para no romper el
  guardado en caché (la columna es `NOT NULL`).

## 2. Ambientes — homologación vs. producción

Todas las acciones aceptan un campo opcional `ambiente: "homologacion" | "produccion"`.
En la Edge Function, **si no se manda, es homologación** (para pruebas: `dummy`, `consultar`).
Producción requiere:
- El campo `ambiente: "produccion"` en el body.
- Un usuario activo (cualquier rol: los cajeros emiten las del día a día). La acción
  `reemitir` es solo para admin.
- Que los secretos de producción estén cargados (si no, la función falla con un mensaje
  claro — nunca hay un reemplazo/fallback silencioso).

Los botones reales (`emitirFacturaCReal` en `packages/shared/lib/arcaFacturacion.ts`, usado
por Facturación y Ventas del día) mandan **`'produccion'` por default** desde docs/59, y
guardan en `facturas_c.ambiente` el ambiente que respondió la función.

La fecha del comprobante se calcula en hora argentina (antes, después de las 21hs salía la
del día siguiente porque el runtime corre en UTC).

### Secretos por ambiente

| Secreto | Ambiente | Notas |
|---|---|---|
| `ARCA_CUIT` | Ambos | CUIT de Virikyna |
| `ARCA_PUNTO_VENTA` | Homologación | Punto de venta `0001` |
| `ARCA_HOMO_CERT` / `ARCA_HOMO_KEY` | Homologación | Certificado y clave de homologación |
| `ARCA_PROD_CERT` / `ARCA_PROD_KEY` | Producción | Certificado y clave real, generados por la dueña en ARCA con su Clave Fiscal |
| `ARCA_PROD_PUNTO_VENTA` | Producción | **Distinto** al de homologación — ver nota abajo |
| `SUPABASE_SERVICE_ROLE_KEY` | Ambos | Se inyecta sola, no hace falta cargarla |

**Nota importante sobre el punto de venta de producción:** en ARCA, cada punto de venta
está atado a UN solo "Sistema" (ej. "Factura en Línea - Monotributo" vs. "Factura
Electrónica - Monotributo - Web Services"). El punto de venta `0001` de Virikyna en
producción real ya estaba tomado por "Factura en Línea" (el sistema manual del sitio de
ARCA) — WSFEv1 (lo que usa esta función) necesitó un punto de venta nuevo y separado,
dado de alta específicamente con Sistema "Web Services". Quedó como **`0002`**
("VIRIKYNA-WEB"). Si en algún momento se factura por los dos sistemas a la vez, son dos
numeraciones independientes, cada una con su propia secuencia de comprobantes.

## 3. Acciones disponibles (Edge Function)

- `dummy` — health check de ARCA (WSAA + WSFE), sin crear nada.
- `ultimo_autorizado` — `FECompUltimoAutorizado`, último número usado en un punto de venta.
- `emitir` — `FECAESolicitar` para Factura C (CbteTipo 11) de una venta real. Devuelve el
  CAE, no persiste nada (eso lo hace `emitirFacturaCReal` con el RPC `emitir_factura_c`).
- `consultar` — `FECompConsultar`, verificación independiente: le pregunta a ARCA qué tiene
  guardado para un comprobante puntual. Es la única forma de confirmar algo en homologación
  (no existe portal web para homologación) y sirve igual en producción como segunda fuente
  además del webservice que emitió el comprobante.

## 4. Condición frente al IVA del receptor (RG 5616)

Desde una resolución de ARCA (RG 5616), todo comprobante debe declarar la condición frente
al IVA de quien compra (`CondicionIVAReceptorId`). Se modela en `clientes.condicion_iva`
(tipo `condicion_iva_cliente`: `consumidor_final` | `responsable_inscripto` |
`monotributista` | `exento` | `no_categorizado`), editable desde el formulario de cliente
en ambas apps. Ventas sin `cliente_id` (consumidor final anónimo) van siempre como
Consumidor Final.

## 5. Prueba de producción realizada

El 14/09/2026 se hizo una única prueba real en producción, autorizada explícitamente por
la dueña, con datos de venta ficticios (la base de datos se resetea antes del lanzamiento
real, así que no hay implicancia de dejar un "hueco" contable):

- Venta N° 32, cliente de prueba (condición IVA: Exento), total $1452.00.
- CAE obtenido: **86372975059318**, vencimiento 24/09/2026.
- Punto de venta `0002`, comprobante `00000001`, Factura C.
- Verificado de forma independiente con `FECompConsultar` contra ARCA producción: el CAE,
  importe y `Resultado: "A"` (Aprobado) coinciden exactamente con lo guardado en
  `facturas_c`.

### Si en algún momento no aparece un comprobante en el portal de ARCA

1. **"Comprobantes en línea" no es la pantalla correcta** para comprobantes emitidos por
   Web Services — esa pantalla solo lista puntos de venta configurados para el sistema
   manual "Factura en Línea". Buscar en cambio **"Consulta de Comprobantes Emitidos"**
   (dentro de la aplicación de Facturación Electrónica en el sitio de ARCA), que sí lista
   comprobantes de cualquier sistema.
2. Esa pantalla de consulta puede tardar en sincronizar (no es en tiempo real) — un
   comprobante recién emitido puede tardar minutos en aparecer ahí.
3. La fuente más confiable e inmediata es siempre `FECompConsultar` (la acción `consultar`
   de la Edge Function) — es el mismo webservice que emitió el comprobante, respondiendo en
   tiempo real. Si esa consulta devuelve `Resultado: "A"` con el CAE esperado, el
   comprobante existe de verdad en ARCA, independientemente de lo que muestre cualquier
   pantalla del portal.
4. Si `FECompConsultar` también fallara con "comprobante no encontrado", ahí sí habría un
   problema real a investigar (verificar que se está consultando el punto de venta y
   número correctos, y el ambiente correcto).

## 6. Pendiente / fuera de alcance por ahora

- No hay Nota de Crédito (ver `06_estructura_de_datos.md`): una Factura C real, una vez
  emitida, no se puede revertir desde el sistema.
- `condicion_iva` de clientes cuenta corriente hay que cargarla manualmente al dar de alta
  o editar el cliente — no hay una forma de consultarla automáticamente contra ARCA
  (existe el método `FEParamGetCondicionIvaReceptor`, no implementado).
