# 05 — Stack Técnico — Virikyna POS

## Resumen de arquitectura

Tres superficies distintas, un solo backend:

```
┌─────────────────────────┐     ┌─────────────────────────┐
│   CAJA (Windows)          │     │  INVENTARIO MÓVIL (5.1)  │
│   Tauri v2 + React/TS     │     │  PWA — Android / iOS     │
│   SQLite local + sync     │     │  Sin motor local          │
└──────────┬───────────────┘     └──────────┬───────────────┘
           │  PowerSync (sync bidireccional) │  HTTPS directo
           └───────────────┬──────────────────┘
                            ▼
                  ┌──────────────────┐
                  │     SUPABASE       │
                  │  Postgres + Auth   │
                  │  + RLS por rol      │
                  └─────────┬─────────┘
                            │ HTTPS directo (solo lectura)
                            ▼
                  ┌──────────────────┐
                  │  PWA DUEÑA         │
                  │  Dashboard/reportes │
                  └──────────────────┘
```

Una sola caja física para arrancar (Terminal #001). El campo `terminal_id` queda preparado en el schema por si en el futuro se suma una segunda caja — no requiere cambios de arquitectura, solo activar PowerSync en la máquina nueva.

---

## 1. Caja — app principal (la que más se usa)

| Capa | Tecnología | Por qué |
|---|---|---|
| UI | React + TypeScript | Consistente con el resto de tu stack (deciDATA) |
| Runtime desktop | **Tauri v2** | Un solo código, compila nativo para Windows y Mac; liviano, actualizaciones automáticas incluidas (plugin updater) |
| Estilos | Tailwind + shadcn/ui | Estándar ya definido en `frontend-standards` |
| Base local | **SQLite embebida** | Lectura/escritura instantánea, funciona sin internet |
| Sincronización | **PowerSync** | Sincroniza SQLite ↔ Supabase en segundo plano; la app nunca espera a la conexión para operar |
| Backend / DB central | **Supabase (Postgres + Auth)** | Centraliza datos, reportes, backup |
| Facturación electrónica | ARCA (WSFEv1) vía Edge Function (`@aledj02/afip.js`) — ver `19_integracion_arca.md` | Obtiene el CAE en tiempo real; corre server-side (Supabase Edge Functions), nunca en el cliente |
| Código de barras | Lector HID (USB) | Se comporta como teclado — cero drivers ni configuración |
| Atajos de teclado | Definidos en Ventas (Enter, E, T, Q, C, D, Esc — ver `04_modulos_y_funciones.md`) | Agilidad de cajero, sin depender del mouse |

**Sin impresora fiscal.** Facturación 100% vía ARCA electrónica, manual: el cajero decide qué comprobantes facturar desde la pestaña Facturación. No hay modo de contingencia offline para facturar — si no hay internet al momento de facturar, la emisión queda pendiente hasta que vuelva la conexión (la venta en sí no se bloquea, solo la Factura C).

---

## 2. Inventario desde celular (Módulo 5.1)

| Capa | Tecnología | Por qué |
|---|---|---|
| Tipo de app | **PWA** (no nativa) | Evita publicación en App Store / Google Play; se instala desde el navegador |
| UI | React + TypeScript, mobile-first | Reutiliza componentes y lógica de Inventario ya construidos en la Caja |
| Datos | Conexión directa a Supabase (sin SQLite local) | No necesita resiliencia offline — es una herramienta de uso puntual, con conexión |
| Código de barras | Cámara del celular + librería de escaneo (ej. `zxing-js` o `@zxing/browser`) | Funciona en navegador, Android e iOS, sin hardware extra |
| Auth | Mismo Supabase Auth que la Caja | Un solo usuario/contraseña para todo el sistema |

---

## 3. PWA de la dueña (fuera del alcance de Fase 1, cotizar aparte como Fase 2)

**No es un dashboard de solo lectura — es la experiencia completa de Admin, salvo Ventas.**

| Capa | Tecnología | Por qué |
|---|---|---|
| Tipo de app | PWA, instalable desde iOS (Safari → "Agregar a inicio") y desde Mac | No opera caja — no necesita Tauri ni SQLite |
| Datos | Lectura **y escritura** directa a Supabase, con rol admin + RLS | Gestiona de verdad, no solo consulta |
| Alcance | Todo lo que ve el Admin en la Caja, **excepto la pantalla de Ventas/cobro** (esa depende del motor local) | Ella no vende, pero gestiona todo lo demás |
| Módulos incluidos | Dashboard, Inventario (alta/edición/baja/ajuste de stock), Proveedores (alta, facturas, pagos), Clientes (alta, cobros), Facturación (emitir/ver/enviar Factura C de ventas ya hechas), Cierre de Caja + Caja Gestión (validar Cierre Z, egresos generales), Configuración (usuarios) | Con creación, edición y eliminación real — mismos permisos que el Admin de la Caja |
| Arquitectura | Reutiliza los componentes de UI de `packages/shared`, con un **adaptador de datos distinto**: esta PWA habla directo con Supabase, la Caja habla con SQLite/PowerSync | Comparte diseño y lógica de negocio, no duplica código, pero sí es una segunda aplicación real |

**Nota de alcance/presupuesto:** al ser CRUD completo (no solo lectura), esto es una segunda aplicación — más chica que la Caja, pero no un agregado menor. Cotizar como Fase 2 propia, igual que 5.1 y 7.1, no como parte de la suscripción mensual.

**Resiliencia:** al escribir directo contra Supabase sin buffer local, si se corta la conexión a mitad de una acción, la PWA debe mostrar el error normal de una web (reintentar) — no tiene la garantía de "nunca se pierde" que sí tiene la Caja con su motor local.

---

## 4. Infraestructura a preparar (deciDATA)

- Proyecto Supabase (Postgres + Auth) dedicado a Virikyna
- Proyecto PowerSync conectado a ese Supabase
- Repositorio de código (monorepo sugerido: `apps/caja`, `apps/inventario-movil`, `apps/dueña`, `packages/shared` para tipos y lógica compartida)
- Certificado de firma de código para Windows (opcional, evita aviso de SmartScreen)
- Definir estrategia de firma/notarización para Mac (cuenta Apple Developer USD 99/año, o workaround manual de Gatekeeper — ver conversación previa, a decidir antes de Fase 7)

## 5. Lo que tiene que gestionar Virikyna (la dueña)

- CUIT de la juguetería
- Clave Fiscal nivel 3
- Punto de venta habilitado en ARCA para factura electrónica
- Certificado digital asociado al CUIT (se genera desde ARCA con la Clave Fiscal)
- Datos completos de fichas de proveedores existentes (razón social, CUIT, dirección, teléfono, mail, contacto) para la carga inicial

## 6. Requisito transversal de diseño

**Letras grandes en toda la UI** — pedido explícito de la dueña. Se define como token de tamaño de fuente base más grande de lo estándar en `08_estilos_y_diseno` (a construir junto con el diseño visual, no cubierto en este documento).

## 7. Historial y Auditoría (nuevo — Virikyna Gestión)

Se implementa 100% en la capa de Supabase, con triggers de Postgres que registran automáticamente cada alta/edición/eliminación en las tablas operativas (ver `06_estructura_de_datos.md`, sección de auditoría). No requiere ninguna tecnología nueva en el stack — es una tabla + triggers + un set de RPCs de reversión.

**Confirmado con la dueña:** una venta ya facturada (con CAE de ARCA) no se puede revertir desde el sistema — es un documento fiscal ya emitido. La Nota de Crédito que permitiría revertirla fiscalmente **queda fuera de alcance de Fase 1**, documentada como límite conocido para una fase futura. El Cierre Z ya validado tampoco se revierte — solo admite una nota de corrección, sin reabrir el día.

## 7.1. Carga inicial y caja general (nuevo — Virikyna Gestión)

También 100% en la capa de Supabase, sin tecnología nueva: se agregan `cuentas` (Efectivo, Mercado Pago, Galicia) y su ledger `movimientos_cuenta`, con el mismo principio que el stock — el saldo nunca se pisa, siempre se suma/resta un movimiento. Esto permite: cargar cuánta plata hay en cada cuenta al arrancar, cargar la deuda inicial de cada proveedor y cliente, y que la dueña anote ingresos/egresos manuales en cualquier momento desde Caja Gestión, además de lo que impacta automático al validar un Cierre Z.

## 8. Deploy y actualizaciones — cómo se actualiza cada superficie

**PWAs (Inventario móvil 5.1 y PWA de la dueña):**
- Deploy: push a git → build automático en Vercel/Netlify → publicado. No hay paso manual de instalación por versión.
- Se actualizan solas: al reabrir la PWA, el navegador detecta el nuevo service worker y refresca. Nadie tiene que reinstalar nada.
- Instalación inicial en iOS: HTTPS + `manifest.json` + ícono (`apple-touch-icon`) → desde Safari, "Compartir" → "Agregar a pantalla de inicio". Queda como ícono normal, abre a pantalla completa.

**Caja (Tauri, Windows y eventualmente Mac):** es distinto — no se actualiza solo por deployar, hay que dejar armado el mecanismo una sola vez:
1. Generar un par de claves de firma propio de Tauri (`tauri signer generate`) — no tiene relación con el certificado de Apple ni con ARCA, es solo para que la app confíe en sus propias actualizaciones.
2. Configurar el plugin `updater` de Tauri con la clave pública embebida.
3. Cada release nueva: compilar con el updater activo, subir el instalador firmado + un manifest JSON (`latest.json`) a donde se hostee (ej. GitHub Releases, o el mismo bucket de Supabase Storage).
4. La app chequea ese manifest al abrir (o periódicamente); si hay versión nueva, la descarga, valida la firma, y se reinicia con la actualización aplicada — sin intervención del cajero.

Este mecanismo se arma una sola vez en Fase 8 y después es transparente para siempre.
