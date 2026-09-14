---
name: supabase-production-patterns
description: Patrones de producción para proyectos Supabase — Row Level Security (RLS) performance y seguridad, manejo de claves (anon vs service_role), Realtime (Postgres Changes vs Broadcast), Edge Functions, backups y migraciones. Usar al configurar RLS en cualquier tabla nueva, al notar queries lentas en producción, al decidir si algo va en Realtime, al escribir una función que necesita saltarse RLS, o al preparar un proyecto Supabase para producción. Complementa (no reemplaza) la skill database-first, que cubre el diseño del schema en sí.
---

# Supabase — patrones de producción

## RLS no es opcional, y el error más común es el silencio

Toda tabla nueva en el schema `public` queda expuesta por la API de Supabase apenas se crea. `ENABLE ROW LEVEL SECURITY` no viene activado por default. Dos fallas simétricas y ambas silenciosas:
- **RLS desactivado**: cualquiera con la `anon key` lee/escribe la tabla entera. No hay error, no hay warning en el código — solo un hueco de seguridad.
- **RLS activado sin políticas**: todas las queries devuelven vacío. La app "funciona" pero no muestra nada, y no hay mensaje de error que lo explique.

Regla de oro: cada `CREATE TABLE` va acompañado, en el mismo commit, de `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` y al menos una policy. Nunca se prueban las políticas desde el SQL Editor del dashboard — ese editor corre con privilegios que **saltan RLS**. Probar siempre desde el cliente (SDK) con un usuario real logueado.

## Performance de RLS: indexar y envolver en SELECT

Una policy mal escrita puede convertir una query de 2ms en una de minutos. Dos reglas que resuelven la mayoría de los casos:
- Indexar toda columna que aparezca dentro de una policy (típicamente `user_id`, o la columna que compara contra `auth.uid()`).
- Envolver las funciones de auth en un `SELECT` dentro de la policy (`(SELECT auth.uid())` en vez de `auth.uid()` directo) — permite que Postgres cachee el resultado por query en vez de evaluarlo por fila.
- Agregar el mismo filtro explícito en el cliente aunque la policy ya lo garantice (`.eq('user_id', userId)` además de la policy) — ayuda al optimizer a elegir el índice correcto, no es redundante en términos de performance.

## `service_role` es la llave maestra — nunca al cliente

`service_role` salta RLS completo. Pertenece exclusivamente a entornos de servidor de confianza (Edge Functions, backend propio) — jamás al bundle de una app de escritorio, móvil o web. Si una función necesita `SECURITY DEFINER` para hacer algo que un usuario normal no podría (ej. crear otro usuario, validar un cierre de caja ajeno), la función en sí debe empezar validando el rol de quien la llama (`auth.uid()` contra la tabla de perfiles) antes de hacer nada — de lo contrario, cualquier usuario autenticado puede invocarla y saltarse toda la seguridad.

## Evitar recursión en policies sobre la tabla de perfiles/roles

Un error clásico: una policy sobre `perfiles` que, para decidir si mostrar una fila, hace un `SELECT` sobre la misma tabla `perfiles` para chequear el rol. Postgres puede entrar en recursión o el comportamiento se vuelve impredecible. Alternativas:
- Guardar el rol en los `custom claims` del JWT (vía Auth Hook) y leerlo de ahí en la policy, sin tocar la tabla.
- O resolver esa gestión particular (alta de usuario, cambio de rol) vía una Edge Function con `service_role`, fuera de RLS, en vez de forzar la policy a auto-referenciarse.

## Realtime: Postgres Changes vs. Broadcast

No son intercambiables:
- **Postgres Changes** (escuchar INSERT/UPDATE/DELETE de una tabla) es el más simple, pero cada cambio se re-evalúa contra RLS por cada cliente conectado — con miles de suscriptores a una tabla activa, es un cuello de botella conocido.
- **Broadcast** manda mensajes efímeros sin tocar la base — ideal para lo que no necesita persistencia (cursores, presencia, "usuario X está escribiendo").
- Regla simple: Postgres Changes para estado durable que debe ser consistente con la base; Broadcast para todo lo de alta frecuencia y efímero.

## Migraciones

- Migraciones chicas y enfocadas, nunca un solo archivo gigante con todo el schema.
- Un proyecto Supabase separado por ambiente (desarrollo, producción) — no una sola base compartida con datos de prueba mezclados con datos reales.
- Nunca correr una migración nueva directo en producción sin probarla antes en desarrollo.
- Revisar si la migración incluye alguna operación que bloquea la tabla (agregar una columna `NOT NULL` sin default en una tabla grande, por ejemplo) antes de aplicarla en horario de uso real.

## Backups

El plan hosteado incluye backups automáticos diarios, pero para algo transaccional (ventas, dinero) conviene no depender solo de eso:
- Backup manual antes de cualquier migración de schema en producción.
- Exportar periódicamente fuera de la plataforma (a otro proveedor de almacenamiento) para no depender de un solo punto de falla.
- Un backup que nunca se probó restaurar no es un backup confiable — probar el proceso de recuperación al menos una vez antes de necesitarlo de verdad.

## Auditoría universal y reversión de acciones

Cuando el negocio pide "ver quién hizo qué" y/o "poder deshacer" cualquier acción del sistema (típico en software de gestión donde el dueño no confía ciegamente en cada empleado, con razón), el patrón correcto no es loggear manualmente desde cada función de negocio — es automatizarlo con triggers, y separar "ver el historial" de "revertir".

**El log se llena solo, vía trigger, nunca a mano:**
```sql
CREATE OR REPLACE FUNCTION fn_auditoria_generica() RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, valores_nuevos, usuario_id)
    VALUES (TG_TABLE_NAME, NEW.id, 'edicion', to_jsonb(OLD), to_jsonb(NEW), auth.uid());
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```
Colgado como `AFTER INSERT OR UPDATE OR DELETE` en cada tabla que deba auditarse. Esto garantiza que ningún cambio quede sin registrar, sin depender de que cada desarrollador se acuerde de agregar el log en cada endpoint nuevo.

**La tabla de auditoría es append-only, ni siquiera el admin la edita:** RLS le da `SELECT` a quien corresponda (típicamente solo admin) y no le da `UPDATE` ni `DELETE` a nadie — ni con `service_role` debería tocarse manualmente en operación normal. El valor del historial es que nadie, ni el dueño del negocio, pueda reescribir lo que pasó.

**"Revertir" es una acción nueva, nunca una edición ni un borrado del registro original de auditoría.** Si se deshace un cambio, se inserta una fila nueva en auditoría (`accion = 'reversion'`, con una FK opcional a la acción que revierte) y se aplica el efecto correspondiente sobre la tabla de negocio. El historial cuenta la verdad completa: qué pasó, y que alguien lo corrigió después — nunca "lo que pasó, editado para que parezca que no pasó".

**No todo movimiento es reversible de la misma forma — no construir un "undo" genérico:**
- Cambios de campo simple (precio, un dato de ficha): reversión = restaurar el valor anterior. Trivial y siempre seguro.
- Movimientos que afectan cantidades (stock, saldos, caja): reversión = un movimiento inverso (contra-asiento), nunca sobreescribir el original. Ver la skill `pos-inventory-architecture` para el mismo principio aplicado a stock.
- Documentos con validez externa ya emitidos (una factura con CAE fiscal, un pago ya confirmado por el banco): **no son reversibles desde el sistema, punto**. La única reversión válida es el mecanismo formal correspondiente (nota de crédito, contracargo), nunca un botón de "deshacer" que borre o edite el documento ya emitido. Detectar este tipo de límite temprano en el diseño y decirlo explícitamente al cliente, en vez de prometer un "deshacer todo" que después no se puede cumplir de forma correcta.

Construir una función `revertir_*` específica por tipo de entidad (no un `undo(auditoria_id)` genérico que intente adivinar qué hacer según la tabla) — cada tipo de reversión tiene su propia validación de negocio y su propio efecto correcto.

## Checklist rápido antes de pasar una tabla a producción

- [ ] RLS habilitado + al menos una policy, probada desde el cliente (no desde el SQL Editor)
- [ ] Columnas usadas en policies, indexadas
- [ ] Funciones `auth.*` envueltas en `SELECT` dentro de las policies
- [ ] Ninguna key `service_role` en código de cliente
- [ ] Funciones `SECURITY DEFINER` validan el rol de quien las llama, al principio de la función
- [ ] Sin policies que se auto-referencian sobre la misma tabla de roles
- [ ] Migraciones chicas, versionadas, probadas en desarrollo antes de producción
