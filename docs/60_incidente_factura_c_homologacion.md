# 60 — Incidente: Factura C emitidas en homologación (octubre 2026)

Registro de lo que pasó, lo que se hizo y lo que queda pendiente. Migración: `docs/59_factura_c_produccion.sql`.
Integración en general: `docs/19_integracion_arca.md`. Commit del arreglo: `acb8196` (rama `lote-oct-2026`).

## 1. Resumen

| | |
|---|---|
| **Qué pasó** | Entre el 19/10 y el 26/10/2026 el sistema emitió 43 Factura C contra el ambiente de **homologación** (prueba) de ARCA. Tenían CAE con formato real (14 dígitos) pero **sin validez fiscal**, y no aparecían en "Mis Comprobantes". |
| **Detectado** | 26/10/2026: en ARCA solo figuraban 2 comprobantes de los muchos que mostraba el sistema. |
| **Corregido** | 26/10/2026, 23:06–23:10: las 43 se re-emitieron en **producción** y se verificaron una por una contra ARCA. |
| **Monto** | $ 2.187.800 (43 facturas, todas a consumidor final) |
| **Pendiente** | Release de Local y Gestión · Consulta con la contadora sobre la condición frente al IVA · Comprobante impreso incompleto (ver §6) |

## 2. Causa

- **No había un CAE simulado.** Todos los caminos de error de la Edge Function `arca-emitir-factura` fallan de forma visible. El sistema sí llamaba a ARCA de verdad.
- La función usaba **homologación por default**: solo emitía en producción si el pedido traía `ambiente: "produccion"`. Los botones de emitir (`emitirFacturaCReal`, usado en Facturación y Ventas del día de Local y Gestión) **nunca mandaban ese campo**. Estaba documentado como pendiente ("falta decidir el corte a producción") y se empezó a facturar a clientes reales sin hacerlo.
- Homologación usa `https://wswhomo.afip.gov.ar/wsfev1/service.asmx` con el punto de venta 00001. Producción usa `https://servicios1.afip.gov.ar/wsfev1/service.asmx` con el punto de venta **0002** (el 0001 de producción es de "Factura en Línea", el sistema manual del sitio de ARCA).
- `facturas_c` no guardaba el ambiente: un CAE de prueba y uno real se veían iguales.
- Evidencia: el token de producción en `arca_wsaa_tokens` no se había renovado desde el 14/09, así que nadie había hablado con ARCA producción desde la prueba de ese día.

**Bug secundario encontrado:** la fecha del comprobante se calculaba en UTC. Las facturas emitidas después de las 21 hs de Argentina salían con la fecha del día siguiente.

## 3. Qué había en ARCA producción antes del arreglo

| Comprobante | Fecha | Receptor | Importe | Origen |
|---|---|---|---|---|
| 0002-00000001 | 14/09/2026 | THEAUX JIMENA (CUIT 27409288001) | $ 1.452 | Prueba de la integración (docs/19 §5). Ya no está en la base: se borró en la limpieza del 13/10. |
| 0001-00000003 | 06/10/2026 | SOSA RAUL EDGARDO (CUIT 23219049129) | $ 50.000 | Hecha a mano en "Factura en Línea". **No es del sistema**; está bien así. |

## 4. Qué se hizo (26/10/2026)

1. **Backup** de la base: `virikyna_2026-10-26_pre-docs59-arca` (ver docs/44).
2. **Migración docs/59** aplicada (test 9/9 antes y después):
   - `facturas_c.ambiente` (`homologacion` | `produccion`, obligatorio).
   - `emitir_factura_c` recibe `p_ambiente`. Default `homologacion`, para que las apps sin actualizar registren bien lo que emiten.
   - RPC nueva `reemitir_factura_c_produccion`: solo admin; reemplaza el comprobante de homologación por el de producción y deja el anterior en `auditoria`.
3. **Edge Function desplegada:**
   - Los cajeros pueden emitir en producción (es lo esperado: el botón de facturación es para ellos).
   - Acción nueva `reemitir` (solo admin).
   - Fecha calculada en hora argentina.
   - Rechaza cualquier respuesta de ARCA sin `Resultado: "A"` o sin un CAE de 14 dígitos.
4. **Código de las apps** (commiteado, **sin release todavía**): `emitirFacturaCReal` emite en producción por default y guarda el ambiente que respondió la función.
5. **Re-emisión** con `scripts/reemitir-facturas-c.ts`: primero una factura de prueba verificada contra ARCA, después las 42 restantes.
6. **Verificación:** las 43 se consultaron con `FECompConsultar` contra ARCA producción. CAE, importe y `Resultado: "A"` coinciden con la base en las 43. El N° 45 no existe en ARCA, así que no se emitió nada de más.
7. **Registros:**
   - 43 filas en `auditoria` (`tabla_afectada = 'facturas_c'`), cada una con el CAE de homologación en `valores_anteriores`.
   - Copia local de cada CAE en `~/Backups/virikyna/reemision-facturas-c-2026-10-26.jsonl`.

### Fechas
ARCA acepta para venta de productos una fecha de comprobante de hasta **5 días antes** de la emisión.
- 40 facturas salieron con su fecha original.
- 3 salieron con **21/10/2026**: venta N° 17 (era del 19/10) y ventas N° 25 y 30 (eran del 20/10). Avisarle a la contadora.

### Detalle de las 43

| Venta | Total | CAE homologación (sin validez) | Comprobante real | Fecha | CAE real |
|---|---|---|---|---|---|
| 17 | $ 49.000 | 86421006692945 | 0002-00000002 | 21/10/2026 ⚠️ | 86439584873795 |
| 25 | $ 21.900 | 86421012770636 | 0002-00000003 | 21/10/2026 ⚠️ | 86439584895722 |
| 30 | $ 105.000 | 86421012790292 | 0002-00000004 | 21/10/2026 ⚠️ | 86439584896532 |
| 32 | $ 24.000 | 86421015012846 | 0002-00000005 | 21/10/2026 | 86439584897326 |
| 52 | $ 21.500 | 86431017607390 | 0002-00000006 | 22/10/2026 | 86439584898047 |
| 53 | $ 59.000 | 86431018271181 | 0002-00000007 | 22/10/2026 | 86439584898754 |
| 61 | $ 9.000 | 86431019648379 | 0002-00000008 | 23/10/2026 | 86439584899653 |
| 63 | $ 39.900 | 86431019725013 | 0002-00000009 | 23/10/2026 | 86439584900382 |
| 62 | $ 70.000 | 86431019725068 | 0002-00000010 | 23/10/2026 | 86439584901341 |
| 65 | $ 39.000 | 86431020037853 | 0002-00000011 | 23/10/2026 | 86439584902091 |
| 74 | $ 12.000 | 86431020155809 | 0002-00000012 | 23/10/2026 | 86439584902766 |
| 71 | $ 48.000 | 86431020155825 | 0002-00000013 | 23/10/2026 | 86439584903369 |
| 70 | $ 15.000 | 86431020155841 | 0002-00000014 | 23/10/2026 | 86439584904124 |
| 81 | $ 42.000 | 86431020173361 | 0002-00000015 | 23/10/2026 | 86439584904679 |
| 77 | $ 40.000 | 86431020173450 | 0002-00000016 | 23/10/2026 | 86439584905329 |
| 76 | $ 20.000 | 86431020173523 | 0002-00000017 | 23/10/2026 | 86439584905950 |
| 78 | $ 7.000 | 86431020183123 | 0002-00000018 | 23/10/2026 | 86439584906595 |
| 84 | $ 83.000 | 86431020186993 | 0002-00000019 | 23/10/2026 | 86439584907305 |
| 86 | $ 79.000 | 86431020610145 | 0002-00000020 | 24/10/2026 | 86439584908097 |
| 90 | $ 155.000 | 86431020633602 | 0002-00000021 | 24/10/2026 | 86439584910097 |
| 97 | $ 28.000 | 86431020662105 | 0002-00000022 | 24/10/2026 | 86439584911454 |
| 104 | $ 49.000 | 86431020677255 | 0002-00000023 | 24/10/2026 | 86439584912939 |
| 115 | $ 20.000 | 86431020709232 | 0002-00000024 | 24/10/2026 | 86439584913867 |
| 112 | $ 85.500 | 86431020709347 | 0002-00000025 | 24/10/2026 | 86439584914473 |
| 107 | $ 16.500 | 86431020709410 | 0002-00000026 | 24/10/2026 | 86439584915254 |
| 128 | $ 95.000 | 86431020988064 | 0002-00000027 | 25/10/2026 | 86439584916019 |
| 129 | $ 79.000 | 86431020990124 | 0002-00000028 | 25/10/2026 | 86439584916682 |
| 130 | $ 23.500 | 86431020991303 | 0002-00000029 | 25/10/2026 | 86439584917581 |
| 136 | $ 23.000 | 86431021013406 | 0002-00000030 | 25/10/2026 | 86439584918079 |
| 137 | $ 55.000 | 86431021021460 | 0002-00000031 | 25/10/2026 | 86439584919203 |
| 138 | $ 6.500 | 86431021023360 | 0002-00000032 | 25/10/2026 | 86439584919614 |
| 139 | $ 7.900 | 86431021028569 | 0002-00000033 | 25/10/2026 | 86439584920333 |
| 143 | $ 18.900 | 86431021048921 | 0002-00000034 | 25/10/2026 | 86439584921156 |
| 147 | $ 17.500 | 86431021069986 | 0002-00000035 | 25/10/2026 | 86439584922026 |
| 162 | $ 94.000 | 86431021085462 | 0002-00000036 | 25/10/2026 | 86439584923001 |
| 156 | $ 85.000 | 86431021085475 | 0002-00000037 | 25/10/2026 | 86439584924175 |
| 176 | $ 125.800 | 86431021102886 | 0002-00000038 | 25/10/2026 | 86439584925281 |
| 177 | $ 11.900 | 86431021102920 | 0002-00000039 | 25/10/2026 | 86439584926020 |
| 165 | $ 170.000 | 86431021102962 | 0002-00000040 | 25/10/2026 | 86439584926855 |
| 180 | $ 135.000 | 86431021113987 | 0002-00000041 | 25/10/2026 | 86439584927827 |
| 181 | $ 66.000 | 86431021951763 | 0002-00000042 | 26/10/2026 | 86439584929256 |
| 198 | $ 20.000 | 86431023883544 | 0002-00000043 | 26/10/2026 | 86439584930564 |
| 195 | $ 15.500 | 86431023886107 | 0002-00000044 | 26/10/2026 | 86439584932037 |

En la tabla, ⚠️ marca las 3 facturas con fecha distinta a la de la venta.

Si un cliente tiene impreso un comprobante con el CAE viejo, se reimprime desde el sistema y sale con el CAE real.

## 5. Pendiente

### 5.1 Release de Local y Gestión
El código ya está commiteado y sale con el próximo release. **Las dos apps emiten facturas** (Facturación y Ventas del día), así que hay que actualizar las dos.

Hasta que salga el release, las versiones instaladas siguen emitiendo en homologación. Esas facturas quedan con `ambiente = 'homologacion'` y se corrigen así:

```
VIRIKYNA_ADMIN_EMAIL=… VIRIKYNA_ADMIN_PASSWORD=… node scripts/reemitir-facturas-c.ts                      # vista previa
VIRIKYNA_ADMIN_EMAIL=… VIRIKYNA_ADMIN_PASSWORD=… node scripts/reemitir-facturas-c.ts --emitir --limite 1  # una de prueba
VIRIKYNA_ADMIN_EMAIL=… VIRIKYNA_ADMIN_PASSWORD=… node scripts/reemitir-facturas-c.ts --emitir             # el resto
```

**Hay que hacerlo dentro de los 5 días**; si no, salen con otra fecha.

Para saber si quedó alguna sin corregir: `SELECT count(*) FROM facturas_c WHERE ambiente = 'homologacion';` tiene que dar 0.

Después del release, verificar la primera factura nueva contra ARCA (ver §6).

### 5.2 Consulta con la contadora: condición frente al IVA ⚠️
El sistema (código y documentación) da por hecho que la emisora es **monotributista**, y por eso emite **Factura C**. La Constancia de Inscripción del 26/10/2026 de **GRION ALICIA CECILIA, CUIT 27-29551383-2** (el mismo CUIT que usa el sistema, secreto `ARCA_CUIT`) muestra otra cosa:

- **No figura Monotributo** ni **IVA** (ni inscripta ni exenta).
- Figuran Ganancias Personas Físicas (activo, 02/2020), Autónomos (02/2020), Bienes Personales (04/2025), Seguridad Social Empleador (03/2026) y "639 – Ganancias simplificada Ley 27.799" (adhesión 23/07/2026).

ARCA aceptó las 44 Factura C, pero qué letra corresponde (A, B o C) depende de la condición frente al IVA. Si no correspondiera la C, el problema alcanza a todas las facturas emitidas. Preguntas para la contadora:

1. ¿Cuál es la condición de Alicia frente al IVA?
2. ¿Corresponde emitir Factura C por la venta de juguetes y libros?
3. ¿Qué tiene que decir el comprobante en "Condición frente al IVA"?
4. Con IIBB "No aportante / No alcanzado", ¿qué se imprime en el comprobante?

### 5.3 Comprobante impreso incompleto
El ticket que genera el sistema (`packages/shared/lib/comprobanteLayout.ts`) dice "FACTURA C", el número y el CAE. **Le falta lo que ARCA exige en una factura electrónica impresa**, también en una Factura C:

- Código QR de ARCA (RG 4892).
- Vencimiento del CAE.
- Código de comprobante 011.
- Datos del emisor: razón social, CUIT, domicilio, condición frente al IVA, IIBB e inicio de actividades.

Además, imprime la fecha de la venta y no la fecha del comprobante (en las 3 facturas del 21/10 no coinciden).

Las facturas son válidas en ARCA; lo que no cumple es el papel o PDF que se le entrega al cliente. **Se decidió no implementarlo hasta tener la respuesta de la contadora (§5.2).**

Datos del emisor según la constancia, para cuando se haga:

| Dato | Valor |
|---|---|
| Razón social | GRION ALICIA CECILIA |
| CUIT | 27-29551383-2 |
| Domicilio | Corrientes 0 Dpto. 11, esq. Ruta N9 (Super Mariano Max), Jesús María (5220), Córdoba |
| Ingresos Brutos | Córdoba, régimen general: No aportante / No alcanzado (desde 12/2025) |
| Inicio de actividades | 02/2020 (actividad principal); venta de juguetes 12/2025, libros 03/2026 |
| Condición frente al IVA | **Pendiente (§5.2)** |

El CAE, su vencimiento y los datos para el QR salen de lo que ya devuelve ARCA. El vencimiento hoy no se guarda en `facturas_c`; para ponerlo en el ticket habría que agregar esa columna.

### 5.4 Riesgos conocidos (no resueltos)
- **Doble clic / dos cajeros sobre la misma venta:** si dos pedidos de emisión de la misma venta llegan casi juntos, ARCA puede emitir dos comprobantes y el segundo no se guarda. El sistema avisa con el CAE para anotarlo a mano. No hay Nota de Crédito para anularlo.
- **No hay Nota de Crédito:** una Factura C real no se puede revertir desde el sistema.

## 6. Cómo verificar un comprobante

- **En el sistema:** Facturación → ver comprobante (número 0002-xxxxxxxx y CAE).
- **En ARCA, en el momento:** la consulta pública de validez de comprobantes ("Consulta de comprobantes – CAE"), sin clave fiscal. Se carga CUIT emisor, tipo 11, punto de venta, número, fecha, importe y CAE.
- **Desde la Edge Function:** acción `consultar` con `ambiente: "produccion"` y `numero` (usa `FECompConsultar`). Es lo que se usó para verificar las 43.
- **"Mis Comprobantes"** se actualiza con demora: que una factura no aparezca ahí todavía no quiere decir que no exista.

## 7. Si hay que volver atrás
- **La base:** el backup `virikyna_2026-10-26_pre-docs59-arca` es anterior a la migración y a la re-emisión. Restaurarlo **no anula** los comprobantes emitidos en ARCA: son irreversibles.
- **Los CAE de homologación originales** están en `auditoria.valores_anteriores` y en el `.jsonl` de `~/Backups/virikyna/`.
