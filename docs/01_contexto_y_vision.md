# 01 — Contexto y Visión — Virikyna POS

## Quién es el cliente

Virikyna es una juguetería grande, con local físico, que hoy opera con **StarPOS Market v1.6.0-013**, un sistema de gestión comercial de escritorio para Windows, de estética y arquitectura anticuadas. El local tiene **conexión a internet inestable**, lo cual condiciona cualquier decisión de arquitectura del sistema nuevo.

## El problema que resuelve este proyecto

El sistema actual funciona, pero:
- No corre en Mac (la dueña usa Mac, la caja usa Windows).
- No tolera bien los cortes de conexión — cualquier operación que dependa de internet en el momento equivocado se traduce en no poder vender.
- La dueña no tiene una vista consolidada y confiable del negocio (caja, stock, cuentas corrientes) — depende de lo que cada cajero carga y de mirar pantalla por pantalla.
- La gestión de márgenes de precio quedaba en manos de quien cargaba la mercadería, lo cual ya generó errores reales (un margen mal cargado por un empleado cubriendo un franco).

## Objetivos del proyecto

1. Reemplazar StarPOS por un sistema a medida, rápido y ágil, que funcione **con o sin buena conexión a internet**.
2. Centralizar stock, proveedores, ventas y caja en una base de datos en la nube, con visibilidad total para la dueña.
3. Facturación electrónica (ARCA) como método principal — **sin impresora fiscal** (corrección de alcance: el local no tiene una, y no se contempla comprarla).
4. Dar a la dueña control real de gestión: márgenes, precios, validación de caja, y trazabilidad completa de quién hizo qué (historial y auditoría, con reversión de acciones).
5. Construir sobre una base técnica sólida que permita crecer en fases sin rehacer nada.

## Cómo se llega a la arquitectura elegida

- **Local-first (SQLite + PowerSync + Supabase)** en la Caja, porque la venta y el cobro no pueden depender de que haya internet en ese momento — la velocidad y disponibilidad del mostrador es la prioridad número uno del negocio.
- **Tauri v2** en vez de Electron o una PWA para la Caja, porque necesita correr nativo en Windows y Mac, con acceso confiable a hardware (lector de código de barras) y actualizaciones automáticas — algo que una PWA no puede garantizar con la misma robustez que pedía este alcance.
- **Tres aplicaciones separadas, no una sola**, porque cada una tiene necesidades muy distintas: Virikyna Local vende (necesita velocidad y funcionar offline), Virikyna Inventario carga mercadería desde el celular (necesita cámara, no necesita motor local), Virikyna Gestión administra el negocio completo salvo vender (necesita CRUD total, no necesita motor local). Comparten diseño y lógica de negocio vía `packages/shared`, pero no comparten la misma capa de datos.
- **Auditoría universal por triggers**, porque la dueña pidió explícitamente poder ver y revertir cualquier movimiento del sistema — esto solo se puede garantizar de forma confiable automatizándolo a nivel de base de datos, no dependiendo de que cada pantalla lo recuerde.

## Quién usa el sistema

| Rol | Usuarios | Qué hace |
|---|---|---|
| **Admin** | Alicia, Ana Julia | Gestión completa del negocio, configuración, validación de caja, auditoría |
| **Cajero** | Jose, Ale, Belu | Ventas, facturación, inventario, proveedores — sin acceso a configuración de usuarios ni auditoría |

Ver `02_roles_y_permisos.md` para el detalle módulo por módulo.

## Las tres aplicaciones (orden de construcción confirmado)

1. **Virikyna Local** — la Caja (Tauri, Windows y Mac). Se construye, se prueba y se valida primero.
2. **Virikyna Inventario** — PWA para celular (Android/iOS), gestión de stock y carga de facturas de proveedor desde cualquier lugar. Se construye después de validar Virikyna Local.
3. **Virikyna Gestión** — PWA para la dueña (iOS y Mac), CRUD completo de administración salvo Ventas. Se construye al final.

## Alcance de Fase 1 (resumen — detalle completo en `04_modulos_y_funciones.md`)

Login y roles, Dashboard, Ventas, Facturación, Inventario y Stock (+ 5.1 desde celular), Proveedores, Cierre de Caja (+ 7.1 Caja Gestión con carga inicial y movimientos manuales), Clientes (cuenta corriente), Configuración de usuarios, e Historial y Auditoría.

## Fuera de alcance de Fase 1 (decisión confirmada, no pendiente)

- Factura A y B
- **Nota de Crédito de venta** — sin esto, una venta ya facturada con CAE no es reversible desde el sistema (ver `03_flujo_de_estados.md`)
- Reportes para el área contable
- Resúmenes y dashboard de balance de negocio para administración
- Futuras actualizaciones y nuevas funciones, a demanda

## Presupuesto y plazos confirmados

- Desarrollo inicial: **$2.500.000** (incluye deploy y compatibilidad Mac)
- Suscripción mensual (uso y soporte técnico): **$65.000**
- Entrega estimada: **20 a 23 días hábiles**
