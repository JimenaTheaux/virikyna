-- 16 — Notas internas (módulo Notas, docs/04_modulos_y_funciones.md módulo 11)
--
-- Contexto: la tabla `notas_internas` (mensaje, autor_id, archivada, archivada_at, created_at)
-- ya fue creada a mano en Supabase antes de este archivo. El CREATE TABLE de acá abajo es
-- IF NOT EXISTS solo como red de seguridad para un entorno nuevo (ej. otra instancia de Supabase) —
-- no se espera que corra nada en la tabla real. Lo nuevo real de este archivo es RLS + la vista.
--
-- Compartida 1:1 por Virikyna Local y Virikyna Gestión, admin y cajero por igual (mismo criterio
-- que ventas/egresos/retiros_caja) — no hay ninguna acción de Notas exclusiva de un rol.

CREATE TABLE IF NOT EXISTS notas_internas (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  mensaje TEXT NOT NULL,
  autor_id UUID NOT NULL REFERENCES perfiles(id),
  archivada BOOLEAN NOT NULL DEFAULT false,
  archivada_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Mismo patrón "_todos" que ventas/egresos/retiros_caja: cualquier usuario activo puede crear,
-- ver y archivar notas — no hay jerarquía de permisos en este módulo.
ALTER TABLE notas_internas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "notas_internas_todos" ON notas_internas;
CREATE POLICY "notas_internas_todos" ON notas_internas FOR ALL USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
);

-- Nombre del autor ya resuelto: `perfiles` solo expone la fila propia por RLS (regla de oro,
-- docs/06 sección 5), así que un cajero no puede ver el nombre de OTRO usuario haciendo un join
-- directo contra `perfiles` desde el cliente. Esta vista hereda el RLS de notas_internas (igual
-- que las vistas de saldo de docs/06 sección 9) y expone perfiles.nombre sin abrir el resto de
-- la ficha de usuario (rol, activo, etc. — mismo espíritu que la vista perfiles_publico).
CREATE OR REPLACE VIEW notas_internas_con_autor AS
SELECT n.*, p.nombre AS autor_nombre
FROM notas_internas n
JOIN perfiles p ON p.id = n.autor_id;
GRANT SELECT ON notas_internas_con_autor TO authenticated;

-- Sin trigger de auditoría a propósito: a diferencia de ventas/stock/cuentas, una nota interna
-- no es un movimiento de negocio reversible (docs/04_modulos_y_funciones.md módulo 10) — es
-- texto libre tipo post-it, sin impacto contable ni operativo que trazar.

-- Verificación: la vista debe devolver el mismo total de filas que la tabla base.
SELECT
  (SELECT count(*) FROM notas_internas) AS total_tabla,
  (SELECT count(*) FROM notas_internas_con_autor) AS total_vista;

-- ─────────────────────────────────────────────────────────────
-- ACTUALIZACIÓN: separación de notas por origen (Local vs Gestión)
-- (docs/04_modulos_y_funciones.md módulo 11, docs/06_estructura_de_datos (1).md sección 15)
-- ─────────────────────────────────────────────────────────────
--
-- Hasta acá `notas_internas` era una sola bandeja compartida 1:1 por las dos apps. Se agrega
-- `origen` para que una nota creada desde Virikyna Gestión no aparezca en Virikyna Local (ni al
-- revés), y para que un cajero no pueda ver ni escribir una nota de Gestión ni a nivel de RLS.
-- Reemplaza la policy original de más arriba — correr una sola vez, después de lo anterior.

ALTER TABLE notas_internas ADD COLUMN origen TEXT NOT NULL DEFAULT 'local'
  CHECK (origen IN ('local', 'gestion'));

-- Las notas ya existentes (creadas antes de esta columna) quedan como 'local' por el DEFAULT:
-- es la única clasificación que no le saca visibilidad a nadie que ya la tenía. Revisar a mano
-- si alguna nota vieja era en realidad de Gestión y reclasificarla con un UPDATE puntual por id
-- (no hay forma automática de saberlo con el dato que había antes de este cambio).

-- IMPORTANTE: recrear la vista acá. `notas_internas_con_autor` (definida más arriba, antes de
-- que existiera `origen`) usa `SELECT n.*` — un CREATE OR REPLACE VIEW fija la lista de columnas
-- al momento en que se ejecuta, no se actualiza sola cuando la tabla de abajo gana una columna.
-- Si esto no se vuelve a correr después del ALTER TABLE, la vista sigue devolviendo las notas
-- sin `origen` y el frontend rompe al filtrar por esa columna.
--
-- `origen` se agrega AL FINAL de la tabla (después de `created_at`), así que con `n.*` pasaría a
-- ocupar la posición donde antes estaba `autor_nombre` — y Postgres rechaza un CREATE OR REPLACE
-- VIEW que le cambia el nombre a una columna ya existente en esa posición (error 42P16). Por eso
-- hace falta DROP + CREATE (no OR REPLACE) con columnas explícitas, listando `autor_nombre` al
-- final a propósito, para que agregar columnas a `notas_internas` en el futuro no vuelva a romper
-- la vista por este mismo motivo.
DROP VIEW IF EXISTS notas_internas_con_autor;
CREATE VIEW notas_internas_con_autor AS
SELECT n.id, n.mensaje, n.autor_id, n.origen, n.archivada, n.archivada_at, n.created_at,
       p.nombre AS autor_nombre
FROM notas_internas n
JOIN perfiles p ON p.id = n.autor_id;
GRANT SELECT ON notas_internas_con_autor TO authenticated;

-- Mismo patrón real de Virikyna (EXISTS contra `perfiles`, sin función helper) que la policy
-- original: cualquier usuario activo puede operar sobre 'local', pero 'gestion' queda restringido
-- a admin — tanto para leer (USING) como para crear/archivar (WITH CHECK).
DROP POLICY IF EXISTS "notas_internas_todos" ON notas_internas;
CREATE POLICY "notas_internas_todos" ON notas_internas FOR ALL USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
  AND (
    origen = 'local'
    OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
  )
) WITH CHECK (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
  AND (
    origen = 'local'
    OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
  )
);

-- Verificado en el proyecto real (ccpinvtleqlsukcqnili): correr todo el bloque de
-- ACTUALIZACIÓN de punta a punta arriba, en un solo tiro, deja la vista y la policy
-- correctas — probado creando una nota origen='gestion' logueado como admin.
-- Confirmar con: SELECT policyname, cmd, qual, with_check FROM pg_policies WHERE
-- tablename = 'notas_internas'; (tiene que aparecer una sola policy y mencionar `origen`).
--
-- Pendiente de probar (no se hizo en esta ronda): loguear como Cajero de prueba en
-- Virikyna Local y confirmar que ninguna nota origen='gestion' aparece — ni por RLS
-- (la policy ya lo bloquea) ni por UI (Local nunca pide ese origen igual). Virikyna
-- Gestión ya bloquea a un cajero antes de esto, al nivel de login (rol !== 'admin'
-- en AuthContext.tsx), así que ese lado no aplica.
