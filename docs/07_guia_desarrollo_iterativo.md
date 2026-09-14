# 07 — Guía de Desarrollo Iterativo — Virikyna POS

Orden de fases según `phased-mvp-planning`, adaptado a este proyecto. **Nunca avanzar a la fase siguiente sin probar la anterior con datos reales.** Cada fase indica qué docs adjuntar en el prompt (según `dev-prompting`).

---

## FASE 0 — Documentación y schema

- [ ] Docs 04, 05, 06, 07 (estos cuatro) revisados y aprobados por la clienta
- [ ] Proyecto Supabase creado
- [ ] Proyecto PowerSync creado y conectado a Supabase
- [ ] Ejecutar `06_estructura_de_datos.md` completo en el SQL Editor de Supabase, en orden: enums → tablas sin FK → tablas con FK → índices → RLS → **triggers de auditoría** → RPCs
- [ ] Verificar que los triggers de auditoría disparan: hacer un UPDATE de prueba en `productos` y confirmar que aparece la fila en `auditoria`
- [ ] Verificar con `SELECT COUNT(*)` en cada tabla (deben existir, vacías)
- [ ] Crear los 5 usuarios iniciales en Supabase Auth (Alicia, Ana Julia, Jose, Ale, Belu) + su fila en `perfiles`
- [ ] Crear las cuentas base en la tabla `cuentas` (Efectivo, Mercado Pago, Galicia — confirmar nombres/cantidad exacta con la dueña)
- [ ] Cargar categorías y proveedores reales de Virikyna (datos que aporta la dueña)
- [ ] Derivar tipos TypeScript del schema (ya arrancados en el doc 06)
- [ ] Sin código de UI todavía

**Adjuntar en el prompt:** `06_estructura_de_datos.md` completo.

---

## FASE 1 — Identidad visual

- [ ] Setup del monorepo: `apps/virikyna-local` (Tauri, la Caja), `apps/virikyna-inventario` (PWA celular), `apps/virikyna-gestion` (PWA dueña), `packages/shared` (tipos + lógica)
- [ ] Tokens de color en Tailwind: coral `#E35D6C` como acento primario (ver paleta completa de la propuesta)
- [ ] **Tipografía base más grande que el estándar** — pedido explícito de la dueña, definir escala antes de construir ningún componente
- [ ] Layout base de la Caja: sidebar / topbar con accesos a los 9 módulos
- [ ] Sin lógica de negocio todavía

**Adjuntar en el prompt:** paleta de marca + captura del prototipo visual ya validado con la clienta.

---

## FASE 2 — Auth y routing

- [ ] Login funcional contra Supabase Auth
- [ ] Cambio de usuario sin cerrar la app
- [ ] Routing protegido por rol (`admin` / `cajero`) — ocultar Configuración a cajero
- [ ] Hook `useAuth` + `usePerfil`
- [ ] Probar con los 5 usuarios reales antes de avanzar

**Adjuntar en el prompt:** `04_modulos_y_funciones.md` (sección Login), tabla de roles.

---

## FASE 3 — ABM base (entidades sin relación primero)

Orden interno obligatorio, por dependencia:

1. Categorías de producto (sin FK)
2. Proveedores — incluir `margen_1_default` / `margen_2_default` en el alta
3. Clientes (cuenta corriente)
4. Productos (depende de categorías y proveedores) — incluir cálculo de `precio_venta` visible en tiempo real mientras se carga costo/margen
5. Stock por ubicación (Local / Depósito) visible en la ficha de producto

**Regla de esta fase:** el campo de margen NO lo edita el cajero libre — el formulario de alta de producto solo pide costo; margen viene precargado del proveedor y es editable solo por admin (ver `04_modulos_y_funciones.md`, módulo 5).

**Adjuntar en el prompt:** `04_modulos_y_funciones.md` (módulos 5, 6, 8), `06_estructura_de_datos.md` (tablas correspondientes).

---

## FASE 4 — Flujo principal: Venta → Facturación

Es la acción más importante del sistema — no avanzar a otra fase hasta que esto funcione de punta a punta con datos reales.

1. Pantalla de Ventas: búsqueda por código de barras, carrito, atajos de teclado (Enter/E/T/Q/C/D/Esc)
2. Cobrar → RPC `confirmar_venta` → genera Comprobante X
3. Envío de comprobante por PDF / mail / WhatsApp
4. Pestaña Facturación: listado de comprobantes, filtros, selección múltiple
5. Emitir Factura C (integración real con ARCA — requiere certificado y clave fiscal de la dueña, gestionar esto en paralelo desde el inicio del proyecto porque suele demorar) — **hecho**, ver `19_integracion_arca.md`
6. Ver/enviar comprobante de Factura C ya emitida

**Probar de punta a punta:** vender un producto real, cobrar, facturar, y confirmar que llega el CAE de ARCA (ambiente de homologación primero, producción después). **Hecho** — probado en homologación (uso diario real, conectado a los botones) y validado una vez en producción real (ver `19_integracion_arca.md`, sección "Prueba de producción realizada"). El botón real de todos los días sigue en homologación a propósito hasta que se decida el corte definitivo a producción.

**Adjuntar en el prompt:** `04_modulos_y_funciones.md` (módulos 3 y 4), `06_estructura_de_datos.md` (ventas, venta_items, facturas_c), el HTML de ciclo de vida ya validado con la clienta.

---

## FASE 5 — Cierre de Caja + Caja Gestión

1. Cierre X: cálculo de totales por forma de pago, sin bloquear
2. Registro de egresos de turno
3. Cierre Z: único por día, efectivo esperado vs. contado, diferencia
4. Caja Gestión (admin): tablero de cierres del día, egresos generales, validación de Cierre Z

**Adjuntar en el prompt:** `04_modulos_y_funciones.md` (módulos 7 y 7.1), `06_estructura_de_datos.md` (cierres_caja, egresos).

---

## FASE 6 — Dashboard

Solo después de que Ventas y Cierre de Caja generen datos reales — el dashboard no tiene sentido con la base vacía.

- [ ] Vista Admin completa (ventas del día, ticket promedio, gráfico semanal, alertas de stock)
- [ ] Vista Cajero (grid simplificado)
- [ ] Alerta de stock bajo usando `stock_minimo` por producto

**Adjuntar en el prompt:** `04_modulos_y_funciones.md` (módulo 2).

---

## Orden de construcción confirmado con la clienta

**Virikyna Local primero (Fases 0-6), completo y validado. Recién después Virikyna Inventario. Recién después Virikyna Gestión.** No se arranca una app nueva sin haber probado la anterior con datos reales.

---

## FASE 7 — Virikyna Inventario (celular)

- [ ] PWA `apps/virikyna-inventario`, login compartido con Virikyna Local
- [ ] Acceso directo post-login a Inventario (sin pasar por un menú general)
- [ ] Mismo cuadro de acciones que Inventario de escritorio (módulo 5), vía `packages/shared`
- [ ] Escaneo de código de barras por cámara (Android e iOS)
- [ ] Acceso directo a carga de facturas de proveedor
- [ ] **Testear y validar con la clienta antes de avanzar a la fase siguiente**

**Adjuntar en el prompt:** `04_modulos_y_funciones.md` (módulo 5.1), `05_stack_tecnico.md` (sección 2).

---

## FASE 8 — Virikyna Gestión (PWA de la dueña)

CRUD completo de Admin salvo Ventas — no es un dashboard de solo lectura (ver `05_stack_tecnico.md`, sección 3).

1. PWA `apps/virikyna-gestion`, instalable en iOS y Mac, conexión directa a Supabase (sin motor local)
2. Dashboard, Inventario, Proveedores, Clientes, Facturación, Cierre de Caja + Caja Gestión — mismos componentes de `packages/shared`, con adaptador de datos a Supabase en vez de SQLite/PowerSync
3. **Módulo nuevo: Historial y Auditoría** — listado cronológico de `auditoria` con filtros (usuario, módulo, tipo de acción, fecha), detalle antes/después, y acciones de reversión según la tabla de reglas del módulo 10 (`04_modulos_y_funciones.md`)
4. Límite ya confirmado con la dueña: una venta ya facturada no se revierte desde el sistema (falta Nota de Crédito, fuera de alcance) — el botón "revertir" simplemente no aparece sobre esas ventas en el Historial; no hay nada que resolver antes de construir esto
5. **Módulo nuevo: Carga inicial** — pantalla de uso único (RPC `cargar_saldos_iniciales`): saldo por cuenta, saldo inicial por proveedor, saldo inicial por cliente
6. **Módulo nuevo: Movimientos de caja general** — la dueña anota ingresos/egresos manuales en cualquier momento (RPC `registrar_movimiento_caja_general`), y ve el saldo e historial de cada cuenta
7. **Testear y validar con la clienta antes de avanzar a la fase siguiente**

**Adjuntar en el prompt:** `04_modulos_y_funciones.md` (módulos 7.1 y 10), `06_estructura_de_datos.md` (secciones de cuentas/movimientos_cuenta, auditoría, y RPCs de reversión).

---

## FASE 9 — Polish y deploy

- [ ] Revisión visual en Mac y Windows reales (no solo en el entorno de desarrollo)
- [ ] Definir estrategia Mac: cuenta Apple Developer vs. workaround de Gatekeeper — probar el flujo de auto-update completo antes de decidir
- [ ] Generar par de claves de firma del updater de Tauri (`tauri signer generate`) y embeber la clave pública en `tauri.conf.json`
- [ ] Armar el pipeline de release: build firmado + `latest.json` publicado en cada versión nueva
- [ ] Build de producción sin errores (Tauri para Windows y Mac, build de las 2 PWA)
- [ ] Variables de entorno de producción (Supabase, PowerSync, credenciales ARCA) fuera del código
- [ ] Cambiar ARCA de homologación a producción (secretos de producción ya cargados y validados con un comprobante real — ver `19_integracion_arca.md`; falta solo pasar `ambiente: 'produccion'` en el botón real de emitir)
- [ ] Ejecutar la Carga inicial real con la dueña presente (saldos de cuentas, saldos de proveedores y clientes) — es el último paso antes de que el sistema empiece a operar de verdad
- [ ] Instalación en el local, carga de catálogo real, capacitación al equipo

---

## Checklist de "listo para lanzar"

- [ ] Flujo completo probado con datos reales de Virikyna (no inventados)
- [ ] Probado en la Mac de la dueña y en la caja Windows del local
- [ ] Build de producción sin errores ni warnings críticos
- [ ] Los 5 usuarios reales creados y probados con su rol correspondiente
- [ ] Catálogo de productos y proveedores reales cargado
- [x] Facturación probada con ARCA en producción (no solo homologación) — comprobante real emitido y verificado el 14/09/2026, ver `19_integracion_arca.md`
- [ ] Sin errores en consola en producción

---

## Reglas de prompting para todas las fases

Aplicar `dev-prompting` en cada sesión de desarrollo:
- Un prompt, una funcionalidad — nunca mezclar dos módulos en un mismo pedido
- Nombrar archivos exactos a leer, nunca "el componente de ventas"
- Para bugs: diagnóstico primero, en un prompt separado, sin tocar código
- Cerrar cada prompt con checklist explícito + `npm run build` sin errores

---

## Pendiente técnico — Configuración (gestión de usuarios, módulo 9)

Durante FASE 2 apareció en producción el riesgo de recursión que ya advertía `06_estructura_de_datos.md` sobre la policy `admin_gestiona_usuarios` de `perfiles` (`FOR ALL` consultando la misma tabla) — devolvía 500 en cualquier lectura de perfil, así que **se hizo `DROP POLICY "admin_gestiona_usuarios" ON perfiles`** y quedó solo `perfil_propio` (`auth.uid() = id`). Esto no rompe nada de lo ya construido (login/rol solo necesitan leer el propio perfil), pero significa que **cuando se construya Configuración (crear/editar/desactivar usuario, blanquear contraseña) hay que resolverlo con RPCs `SECURITY DEFINER`, no con otra policy que se auto-referencie sobre `perfiles`** — editar/desactivar va en un RPC que valida `auth.uid()` es admin al principio (corre como dueño de la función, sin pasar por RLS, sin recursión); crear usuario y blanquear contraseña tocan `auth.users` y necesitan la Admin API de Supabase (`service_role`), lo que implica una Edge Function, nunca la key en el bundle de la Caja.

**Actualización Fase 5:** Cierre de Caja necesitaba mostrar el nombre de OTRO usuario (quién hizo el cierre, quién lo validó), y con solo `perfil_propio` esa lectura volvía vacía por RLS. Se agregó `perfiles_lectura_activos` (`FOR SELECT USING (activo = true)`, sin auto-referencia — ver `06_estructura_de_datos.md` sección 10) en vez de tocar la policy de escritura, que sigue pendiente de resolver vía RPC/Edge Function como está descripto arriba.
