# 02 — Roles y Permisos — Virikyna POS

## Los dos roles del sistema

| Rol | Usuarios reales | Perfil |
|---|---|---|
| **Admin** | Alicia, Ana Julia | Gestión completa del negocio: configuración, validación de caja, auditoría, márgenes |
| **Cajero** | Jose, Ale, Belu | Operación diaria: ventas, facturación, inventario, proveedores |

No hay más roles en Fase 1 (no hay "supervisor" intermedio, ni perfil de solo-lectura dentro de Virikyna Local/Inventario).

## Las tres aplicaciones y quién entra a cada una

| Aplicación | Admin | Cajero |
|---|---|---|
| **Virikyna Local** (la Caja) | ✅ | ✅ |
| **Virikyna Inventario** (celular) | ✅ | ✅ |
| **Virikyna Gestión** (PWA dueña) | ✅ (exclusiva Admin) | ❌ |

## Matriz maestra de permisos por módulo

Fuente de verdad detallada en `04_modulos_y_funciones.md` — esta tabla es el resumen para consulta rápida.

| Módulo | Acción | Admin | Cajero |
|---|---|---|---|
| Login | Iniciar sesión / cambiar de usuario | ✅ | ✅ |
| Login | Blanquear contraseña / crear usuario | ✅ | ❌ |
| Dashboard | Ver panel completo (Admin) | ✅ | — |
| Dashboard | Ver grid simplificado (Cajero) | — | ✅ |
| Ventas | Todas las acciones de venta (agregar, editar, cobrar, cancelar, descuento, recargo) | ✅ | ✅ |
| Facturación | Ver, filtrar, seleccionar, emitir Factura C, enviar comprobante | ✅ | ✅ |
| Inventario y Stock | Ver, alta, editar, eliminar, inactivar/reactivar, actualización masiva de precios | ✅ | ✅ |
| Inventario y Stock | **Ajustar stock manualmente** | ✅ | ❌ |
| Inventario desde celular (5.1) | Mismas acciones que Inventario, mismas excepciones | ✅ | ✅ |
| Proveedores | Todas las acciones (alta, editar, asociar productos, cargar factura, registrar pago, ver cta. cte., eliminar) | ✅ | ✅ |
| Inicio de Caja (6.5) | Abrir caja (confirmar o modificar el monto de apertura) | ✅ | ✅ |
| Cierre de Caja | Cierre X, Cierre Z, registrar egreso, ingresar efectivo contado, ver historial | ✅ | ✅ |
| Caja Gestión (7.1) | Validar Cierre Z, registrar egresos generales, carga inicial, movimientos manuales de caja | ✅ | ❌ (módulo exclusivo de Virikyna Gestión) |
| Clientes | Todas las acciones (alta, editar, ver cta. cte., registrar pago, eliminar) | ✅ | ✅ |
| Configuración (usuarios) | Ver, crear, editar, blanquear contraseña, desactivar usuario | ✅ | ❌ |
| Historial y Auditoría (10) | Ver historial, ver detalle, revertir, nota de corrección | ✅ | ❌ (módulo exclusivo de Virikyna Gestión) |

## Excepciones puntuales a memorizar (las que rompen el patrón "ambos roles")

Todo el sistema sigue el mismo patrón por defecto — **Admin y Cajero acceden igual** — salvo estas cinco excepciones, todas del lado de restringir al Cajero:

1. **Ajuste manual de stock** — exclusivo Admin (para que quien se equivocó cargando no pueda "corregirlo" sin trazabilidad).
2. **Configuración de usuarios** — exclusivo Admin.
3. **Caja Gestión completa** (validar Cierre Z, carga inicial, movimientos manuales) — exclusivo Admin, y solo existe en Virikyna Gestión.
4. **Historial y Auditoría completo** (ver, revertir) — exclusivo Admin, y solo existe en Virikyna Gestión.
5. **Blanquear contraseña / crear usuario** — exclusivo Admin.

## Regla de implementación (ver `06_estructura_de_datos.md`)

Cada excepción se valida en **dos capas, no una sola**: la política RLS de Supabase (para que la consulta ni siquiera devuelva datos a quien no corresponde) y la función RPC correspondiente (para que la acción en sí rechace explícitamente al rol equivocado, con un mensaje claro). Nunca ocultar una acción solo en el frontend — un cajero con las devtools abiertas no debería poder ejecutar una acción de Admin aunque el botón esté escondido.
