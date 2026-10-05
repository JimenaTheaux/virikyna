-- 27 — Alertas de apertura de caja con diferencia: marcar como revisada
--
-- Contexto: el Dashboard de Virikyna Gestión mostraba las 5 aperturas con diferencia más
-- recientes, sin fecha ni estado — una diferencia vieja seguía apareciendo hasta que la tapaban
-- 5 nuevas, y una nueva podía quedar escondida detrás de 5 viejas. aperturas_caja no tiene
-- policy de UPDATE (docs/21): todo cambio pasa por una RPC SECURITY DEFINER.
--
-- Este patch agrega quién y cuándo revisó cada apertura. La alerta pasa a mostrar todas las
-- pendientes (sin límite), y la dueña las va marcando como revisadas. El registro de la apertura
-- no se borra ni se modifica en nada más: solo se completan revisada_por / revisada_at.

-- ============================================================
-- 1. Columnas nuevas (nullable: null = pendiente de revisión)
-- ============================================================
ALTER TABLE aperturas_caja ADD COLUMN IF NOT EXISTS revisada_por UUID REFERENCES perfiles(id);
ALTER TABLE aperturas_caja ADD COLUMN IF NOT EXISTS revisada_at TIMESTAMPTZ;

-- Sin policy de UPDATE nueva — igual que en docs/21, el único camino para escribir es una RPC
-- SECURITY DEFINER (abrir_caja, cerrar_caja y ahora marcar_apertura_revisada).

-- ============================================================
-- 2. marcar_apertura_revisada — exclusivo Admin
-- Valida rol en la RPC (segunda capa, docs/02 "Regla de implementación"): un cajero que la
-- llame directo recibe el error aunque no tenga el botón. El UPDATE dispara
-- trg_auditoria_aperturas_caja (docs/21), así que la revisión queda en auditoria.
-- ============================================================
CREATE OR REPLACE FUNCTION marcar_apertura_revisada(p_apertura_id UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_apertura aperturas_caja%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede marcar una apertura como revisada';
  END IF;

  -- FOR UPDATE: si dos admins la marcan a la vez, el segundo espera y ve que ya está revisada.
  SELECT * INTO v_apertura FROM aperturas_caja WHERE id = p_apertura_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Apertura de caja no encontrada'; END IF;
  IF v_apertura.diferencia = 0 THEN RAISE EXCEPTION 'Esta apertura no tiene diferencia para revisar'; END IF;
  IF v_apertura.revisada_at IS NOT NULL THEN RAISE EXCEPTION 'Esta apertura ya fue marcada como revisada'; END IF;

  UPDATE aperturas_caja SET revisada_por = auth.uid(), revisada_at = now()
  WHERE id = p_apertura_id;
END;
$$;

GRANT EXECUTE ON FUNCTION marcar_apertura_revisada(UUID) TO authenticated;

-- ============================================================
-- 3. aperturas_con_diferencia_pendientes
-- Todas las aperturas con diferencia sin revisar, más nuevas primero, sin límite — no depende de
-- ningún filtro de período. El nombre sale del JOIN con perfiles_publico (sin segunda consulta
-- desde el cliente). LEFT JOIN porque perfiles_publico solo lista usuarios activos: la apertura de
-- un cajero ya desactivado tiene que seguir apareciendo (con usuario_nombre null).
-- SECURITY INVOKER: respeta la RLS de aperturas_caja (policy aperturas_ver_todos).
-- ============================================================
CREATE OR REPLACE FUNCTION aperturas_con_diferencia_pendientes()
RETURNS TABLE (
  id UUID,
  monto_esperado NUMERIC,
  monto_real NUMERIC,
  diferencia NUMERIC,
  usuario_id UUID,
  usuario_nombre TEXT,
  abierta_at TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT a.id, a.monto_esperado, a.monto_real, a.diferencia, a.usuario_id,
         pp.nombre::text AS usuario_nombre, a.abierta_at
  FROM aperturas_caja a
  LEFT JOIN perfiles_publico pp ON pp.id = a.usuario_id
  WHERE a.diferencia <> 0
    AND a.revisada_at IS NULL
  ORDER BY a.abierta_at DESC;
$$;

GRANT EXECUTE ON FUNCTION aperturas_con_diferencia_pendientes() TO authenticated;

-- ============================================================
-- Verificación 1: pendientes antes de marcar.
-- ============================================================
SELECT * FROM aperturas_con_diferencia_pendientes();

-- Verificación 2 (logueado como cajero, desde Virikyna Local o con su JWT): debe fallar con
-- 'Solo un administrador puede marcar una apertura como revisada'.
--   SELECT marcar_apertura_revisada('<id de una pendiente>');
-- Desde la API: supabase.rpc('marcar_apertura_revisada', { p_apertura_id: '<id>' }) con sesión de cajero.

-- Verificación 3: después de marcar una como admin, el registro sigue existiendo, con
-- revisada_por / revisada_at completos, y ya no aparece en la verificación 1.
SELECT id, diferencia, abierta_at, revisada_por, revisada_at
FROM aperturas_caja
WHERE revisada_at IS NOT NULL
ORDER BY revisada_at DESC
LIMIT 5;

-- Verificación 4: marcar dos veces la misma debe fallar con 'Esta apertura ya fue marcada como revisada'.

-- Verificación 5: la revisión deja su fila en auditoria (accion de edición sobre aperturas_caja).
SELECT a.created_at, a.tabla_afectada, a.accion, a.registro_id
FROM auditoria a
WHERE a.tabla_afectada = 'aperturas_caja' AND a.created_at > now() - interval '5 minutes'
ORDER BY a.created_at DESC;
