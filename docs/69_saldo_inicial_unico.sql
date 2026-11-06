-- 69 — Saldo inicial único por cuenta: fecha, usuario, protección, corrección con motivo y
--      "a cuenta" que primero cancela el saldo inicial
--
-- Estado: ver el bloque "APLICADO" al final del encabezado (se completa al aplicar).
-- Base: docs/DIAGNOSTICO_SALDOS_INICIALES.md (2026-11-05). Schema relevado sobre el backup
-- virikyna_2026-11-05_pre-docs69-test (ya incluye docs/68).
--
-- Correr desde la raíz del repo, después de 68. La PARTE A es re-corrible (IF NOT EXISTS / CREATE OR
-- REPLACE / backfill con WHERE … IS NULL). La PARTE B solo lee. La PARTE C es un test
-- (BEGIN … ROLLBACK) que no consume secuencias: se puede correr en producción.
--
-- Decisión (dueña, 2026-11-05): el saldo inicial es ÚNICO por cuenta. No suma. Si falta deuda, se
-- carga como comprobante. Si hay un error, se corrige con motivo.
--
-- Qué hace:
--   1. proveedores y clientes: saldo_inicial_fecha + saldo_inicial_usuario_id (→ perfiles).
--      Backfill desde auditoria: fecha y usuario del UPDATE que llevó saldo_inicial de 0 al monto
--      vigente (hoy: GUTIERREZ, TOYCO y LUX ATLANTIC, los tres por Alicia).
--   2. Trigger trg_proteger_saldo_inicial (proveedores y clientes): solo un admin cambia
--      saldo_inicial / _fecha / _usuario_id (las apps escriben esas tablas directo, RLS abierta a
--      cualquier perfil activo). Si un admin cambia el monto sin tocar la fecha, la estampa.
--      Sin sesión (SQL de mantenimiento, auth.uid() null) se permite, igual que docs/68.
--   3. cargar_saldos_iniciales: valida TODO antes de escribir. Si una cuenta, proveedor o cliente
--      ya tiene saldo inicial, rechaza el envío entero listando los NOMBRES (antes: el UUID del
--      primero). Setea fecha y usuario. Deja en auditoria una fila con nota "Carga inicial".
--   4. corregir_saldo_inicial(tipo, id, monto_nuevo, motivo): solo admin, motivo obligatorio,
--      REEMPLAZA el monto (no suma), actualiza fecha y usuario, auditoria con motivo.
--      Solo proveedor/cliente: el saldo inicial de una cuenta de dinero es un movimiento
--      (contra-asiento), fuera de alcance.
--   5. revertir_edicion (Historial): ya no restaura saldo_inicial/_fecha/_usuario_id. Antes,
--      revertir CUALQUIER edición vieja de un proveedor (un teléfono) devolvía el saldo inicial
--      al valor de ese momento. Una edición que solo cambió el saldo inicial no se revierte desde
--      el Historial: se corrige con corregir_saldo_inicial.
--   6. Vistas (mismas columnas en el mismo orden + nuevas al final, security_invoker repetido):
--        pagos_proveedor_a_cuenta / pagos_cliente_a_cuenta: + cancela_saldo_inicial, a_cuenta_libre.
--          Los pagos sin comprobante, del más viejo al más nuevo, cancelan primero el saldo
--          inicial (si es positivo); lo que sobra es a_cuenta_libre.
--        proveedores_a_cuenta: + a_cuenta_libre.
--        proveedores_saldo / clientes_saldo: + saldo_inicial_fecha, saldo_inicial_usuario_id,
--          saldo_inicial_usuario_nombre, saldo_inicial_pendiente, a_cuenta_libre.
--      Identidad (proveedor): saldo_actual = saldo_inicial_pendiente + Σ saldo_pendiente
--                                            − Σ crédito NC − a_cuenta_libre.
--      La columna a_cuenta (cruda) no cambia: la siguen usando los chequeos de docs/37 y docs/52.
--   7. aplicar_pagos_a_cuenta / aplicar_cobros_a_cuenta: aplican solo a_cuenta_libre. Antes, los
--      pagos que cancelaron un saldo inicial se podían aplicar otra vez a una factura nueva.
--   8. formato_pesos(numeric): "$ 1.972.962,10" para los mensajes de error.
--
-- No cambia: el orden de imputación de registrar_pago_proveedor_v2/_v3 y registrar_cobro_cliente
-- (siguen yendo a los comprobantes más viejos; lo que sobra queda a cuenta y, por la vista, cancela
-- el saldo inicial). Ni los formularios de alta/edición de proveedor y cliente.
--
-- APLICADO: 2026-11-06 08:16 (hora AR), PARTE A en producción. Backup previo
-- virikyna_2026-11-06_pre-docs69-aplicar. Antes: probada en restauración local (dos veces seguidas)
-- y con BEGIN … ROLLBACK en producción. Después: B1 = GUTIERREZ (20/10 09:32), TOYCO (20/10 09:34)
-- y LUX ATLANTIC (03/11 11:45), los tres por Alicia; pendiente 0; a cuenta libre 0 (LUX 0,02 =
-- su −0,02 a favor). B2 sin filas. B3 security_invoker en las 5 vistas. PARTE C: OK T1–T10.
-- Permisos: vistas solo SELECT para authenticated; RPCs sin anon; 2 triggers; 0 UPDATE sin WHERE.

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ─── 1. Columnas ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.proveedores ADD COLUMN IF NOT EXISTS saldo_inicial_fecha timestamptz;
ALTER TABLE public.proveedores ADD COLUMN IF NOT EXISTS saldo_inicial_usuario_id uuid REFERENCES public.perfiles(id);
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS saldo_inicial_fecha timestamptz;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS saldo_inicial_usuario_id uuid REFERENCES public.perfiles(id);
COMMENT ON COLUMN public.proveedores.saldo_inicial IS 'Deuda con la que arranca en el sistema. Único: se carga una vez (cargar_saldos_iniciales) y se corrige con motivo (corregir_saldo_inicial). Solo admin. docs/69.';
COMMENT ON COLUMN public.clientes.saldo_inicial IS 'Deuda con la que arranca en el sistema. Único: se carga una vez (cargar_saldos_iniciales) y se corrige con motivo (corregir_saldo_inicial). Solo admin. docs/69.';
COMMENT ON COLUMN public.proveedores.saldo_inicial_fecha IS 'docs/69: cuándo se cargó o corrigió por última vez el saldo inicial. NULL = nunca se cargó.';
COMMENT ON COLUMN public.clientes.saldo_inicial_fecha IS 'docs/69: cuándo se cargó o corrigió por última vez el saldo inicial. NULL = nunca se cargó.';
COMMENT ON COLUMN public.proveedores.saldo_inicial_usuario_id IS 'docs/69: quién cargó o corrigió por última vez el saldo inicial.';
COMMENT ON COLUMN public.clientes.saldo_inicial_usuario_id IS 'docs/69: quién cargó o corrigió por última vez el saldo inicial.';

-- ─── 2. Formato de pesos para mensajes ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.formato_pesos(p numeric) RETURNS text
  LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $$
  SELECT CASE WHEN p < 0 THEN '−$ ' ELSE '$ ' END
         || translate(to_char(abs(p), 'FM999,999,999,990.00'), ',.', '.,')
$$;
COMMENT ON FUNCTION public.formato_pesos(numeric) IS 'docs/69: "$ 1.972.962,10" (formato argentino) para mensajes de error de las RPCs.';
REVOKE ALL ON FUNCTION public.formato_pesos(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.formato_pesos(numeric) TO authenticated, service_role;

-- ─── 3. Backfill desde auditoria (sin sesión: el trigger del punto 4 todavía no existe) ───────
-- La última edición que dejó saldo_inicial en el valor vigente viniendo de otro valor.
DO $$
DECLARE
  r RECORD;
BEGIN
  PERFORM set_config('virikyna.suppress_audit', 'true', true);
  FOR r IN
    SELECT DISTINCT ON (a.tabla_afectada, a.registro_id)
           a.tabla_afectada, a.registro_id, a.created_at, a.usuario_id
    FROM auditoria a
    WHERE a.tabla_afectada IN ('proveedores', 'clientes')
      AND a.accion IN ('alta', 'edicion')
      AND COALESCE((a.valores_nuevos->>'saldo_inicial')::numeric, 0) <> 0
      AND (a.valores_nuevos->>'saldo_inicial') IS DISTINCT FROM (a.valores_anteriores->>'saldo_inicial')
    ORDER BY a.tabla_afectada, a.registro_id, a.created_at DESC
  LOOP
    IF r.tabla_afectada = 'proveedores' THEN
      UPDATE proveedores p SET saldo_inicial_fecha = r.created_at, saldo_inicial_usuario_id = r.usuario_id
      WHERE p.id = r.registro_id AND p.saldo_inicial_fecha IS NULL AND p.saldo_inicial <> 0
        AND p.saldo_inicial = (SELECT (a.valores_nuevos->>'saldo_inicial')::numeric FROM auditoria a
                               WHERE a.tabla_afectada = 'proveedores' AND a.registro_id = r.registro_id
                                 AND a.created_at = r.created_at LIMIT 1);
    ELSE
      UPDATE clientes c SET saldo_inicial_fecha = r.created_at, saldo_inicial_usuario_id = r.usuario_id
      WHERE c.id = r.registro_id AND c.saldo_inicial_fecha IS NULL AND c.saldo_inicial <> 0
        AND c.saldo_inicial = (SELECT (a.valores_nuevos->>'saldo_inicial')::numeric FROM auditoria a
                               WHERE a.tabla_afectada = 'clientes' AND a.registro_id = r.registro_id
                                 AND a.created_at = r.created_at LIMIT 1);
    END IF;
  END LOOP;
  PERFORM set_config('virikyna.suppress_audit', 'false', true);

  -- Ningún saldo inicial vigente puede quedar sin fecha.
  IF EXISTS (SELECT 1 FROM proveedores WHERE saldo_inicial <> 0 AND saldo_inicial_fecha IS NULL)
     OR EXISTS (SELECT 1 FROM clientes WHERE saldo_inicial <> 0 AND saldo_inicial_fecha IS NULL) THEN
    RAISE EXCEPTION 'docs/69 backfill: hay saldos iniciales sin rastro en auditoria (%; %)',
      (SELECT string_agg(razon_social, ', ') FROM proveedores WHERE saldo_inicial <> 0 AND saldo_inicial_fecha IS NULL),
      (SELECT string_agg(COALESCE(razon_social, nombre_fantasia), ', ') FROM clientes WHERE saldo_inicial <> 0 AND saldo_inicial_fecha IS NULL);
  END IF;
END $$;

-- ─── 4. Protección: solo admin ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_proteger_saldo_inicial() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_admin boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;
  v_admin := EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true);

  IF TG_OP = 'INSERT' THEN
    IF NEW.saldo_inicial <> 0 OR NEW.saldo_inicial_fecha IS NOT NULL OR NEW.saldo_inicial_usuario_id IS NOT NULL THEN
      IF NOT v_admin THEN
        RAISE EXCEPTION 'Solo un administrador puede cargar el saldo inicial';
      END IF;
      IF NEW.saldo_inicial <> 0 AND NEW.saldo_inicial_fecha IS NULL THEN
        NEW.saldo_inicial_fecha := now();
        NEW.saldo_inicial_usuario_id := auth.uid();
      END IF;
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.saldo_inicial IS DISTINCT FROM OLD.saldo_inicial
     OR NEW.saldo_inicial_fecha IS DISTINCT FROM OLD.saldo_inicial_fecha
     OR NEW.saldo_inicial_usuario_id IS DISTINCT FROM OLD.saldo_inicial_usuario_id THEN
    IF NOT v_admin THEN
      RAISE EXCEPTION 'Solo un administrador puede modificar el saldo inicial (se corrige desde Caja Gestión → Carga inicial)';
    END IF;
    IF NEW.saldo_inicial IS DISTINCT FROM OLD.saldo_inicial
       AND NEW.saldo_inicial_fecha IS NOT DISTINCT FROM OLD.saldo_inicial_fecha THEN
      NEW.saldo_inicial_fecha := now();
      NEW.saldo_inicial_usuario_id := auth.uid();
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_proteger_saldo_inicial() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_proteger_saldo_inicial ON public.proveedores;
CREATE TRIGGER trg_proteger_saldo_inicial BEFORE INSERT OR UPDATE ON public.proveedores
  FOR EACH ROW EXECUTE FUNCTION public.fn_proteger_saldo_inicial();
DROP TRIGGER IF EXISTS trg_proteger_saldo_inicial ON public.clientes;
CREATE TRIGGER trg_proteger_saldo_inicial BEFORE INSERT OR UPDATE ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.fn_proteger_saldo_inicial();

-- ─── 5. cargar_saldos_iniciales (misma firma) ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.cargar_saldos_iniciales(p_saldos_cuentas jsonb, p_saldos_proveedores jsonb, p_saldos_clientes jsonb)
  RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_cuentas jsonb := COALESCE(p_saldos_cuentas, '[]'::jsonb);
  v_proveedores jsonb := COALESCE(p_saldos_proveedores, '[]'::jsonb);
  v_clientes jsonb := COALESCE(p_saldos_clientes, '[]'::jsonb);
  v_item jsonb;
  v_monto numeric;
  v_conflictos text;
  v_ant jsonb;
  v_nue jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede cargar los saldos iniciales';
  END IF;

  -- ── Montos: numéricos y distintos de cero ──
  IF EXISTS (
    SELECT 1 FROM (
      SELECT e FROM jsonb_array_elements(v_cuentas) e
      UNION ALL SELECT e FROM jsonb_array_elements(v_proveedores) e
      UNION ALL SELECT e FROM jsonb_array_elements(v_clientes) e
    ) s
    WHERE jsonb_typeof(s.e->'monto') IS DISTINCT FROM 'number' OR (s.e->>'monto')::numeric = 0
  ) THEN
    RAISE EXCEPTION 'Cada saldo inicial necesita un monto distinto de cero';
  END IF;

  -- ── Sin repetidos y todos existentes ──
  IF (SELECT count(*) FROM jsonb_array_elements(v_cuentas)) <> (SELECT count(DISTINCT e->>'cuenta_id') FROM jsonb_array_elements(v_cuentas) e)
     OR (SELECT count(*) FROM jsonb_array_elements(v_proveedores)) <> (SELECT count(DISTINCT e->>'proveedor_id') FROM jsonb_array_elements(v_proveedores) e)
     OR (SELECT count(*) FROM jsonb_array_elements(v_clientes)) <> (SELECT count(DISTINCT e->>'cliente_id') FROM jsonb_array_elements(v_clientes) e) THEN
    RAISE EXCEPTION 'Hay una cuenta repetida en la carga inicial';
  END IF;
  IF (SELECT count(*) FROM cuentas WHERE id IN (SELECT (e->>'cuenta_id')::uuid FROM jsonb_array_elements(v_cuentas) e)) <> jsonb_array_length(v_cuentas)
     OR (SELECT count(*) FROM proveedores WHERE id IN (SELECT (e->>'proveedor_id')::uuid FROM jsonb_array_elements(v_proveedores) e)) <> jsonb_array_length(v_proveedores)
     OR (SELECT count(*) FROM clientes WHERE id IN (SELECT (e->>'cliente_id')::uuid FROM jsonb_array_elements(v_clientes) e)) <> jsonb_array_length(v_clientes) THEN
    RAISE EXCEPTION 'Alguna de las cuentas de la carga inicial no existe (recargá la pantalla)';
  END IF;

  -- ── Lock: dos cargas simultáneas de la misma cuenta se serializan ──
  PERFORM 1 FROM cuentas WHERE id IN (SELECT (e->>'cuenta_id')::uuid FROM jsonb_array_elements(v_cuentas) e) FOR UPDATE;
  PERFORM 1 FROM proveedores WHERE id IN (SELECT (e->>'proveedor_id')::uuid FROM jsonb_array_elements(v_proveedores) e) FOR UPDATE;
  PERFORM 1 FROM clientes WHERE id IN (SELECT (e->>'cliente_id')::uuid FROM jsonb_array_elements(v_clientes) e) FOR UPDATE;

  -- ── Único: si alguna ya tiene saldo inicial, no se escribe nada y se nombran todas ──
  SELECT string_agg(t.x, '; ' ORDER BY t.orden, t.x) INTO v_conflictos
  FROM (
    SELECT 1 AS orden, c.nombre || ' (' || formato_pesos(m.monto) || ')' AS x
    FROM jsonb_array_elements(v_cuentas) e
    JOIN cuentas c ON c.id = (e->>'cuenta_id')::uuid
    JOIN movimientos_cuenta m ON m.cuenta_id = c.id AND m.tipo = 'saldo_inicial'
    UNION ALL
    SELECT 2, p.razon_social || ' (' || formato_pesos(p.saldo_inicial)
              || COALESCE(', cargado el ' || to_char(p.saldo_inicial_fecha AT TIME ZONE 'America/Argentina/Buenos_Aires', 'DD/MM/YYYY'), '') || ')'
    FROM jsonb_array_elements(v_proveedores) e
    JOIN proveedores p ON p.id = (e->>'proveedor_id')::uuid
    WHERE p.saldo_inicial <> 0 OR p.saldo_inicial_fecha IS NOT NULL
    UNION ALL
    SELECT 3, COALESCE(c.razon_social, c.nombre_fantasia) || ' (' || formato_pesos(c.saldo_inicial)
              || COALESCE(', cargado el ' || to_char(c.saldo_inicial_fecha AT TIME ZONE 'America/Argentina/Buenos_Aires', 'DD/MM/YYYY'), '') || ')'
    FROM jsonb_array_elements(v_clientes) e
    JOIN clientes c ON c.id = (e->>'cliente_id')::uuid
    WHERE c.saldo_inicial <> 0 OR c.saldo_inicial_fecha IS NOT NULL
  ) t;
  IF v_conflictos IS NOT NULL THEN
    RAISE EXCEPTION 'Ya tienen saldo inicial cargado y no se suma: %. No se guardó nada. Si falta deuda, cargala como comprobante; si el monto está mal, usá Corregir.', v_conflictos;
  END IF;

  -- ── Cuentas de dinero: un movimiento por cuenta (índice único) ──
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_cuentas) LOOP
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, usuario_id)
    VALUES ((v_item->>'cuenta_id')::uuid, 'saldo_inicial', round((v_item->>'monto')::numeric, 2), 'Carga inicial del sistema', auth.uid());
  END LOOP;

  -- ── Proveedores y clientes: campo de la ficha + auditoria con nota ──
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_proveedores) LOOP
    v_monto := round((v_item->>'monto')::numeric, 2);
    SELECT to_jsonb(p) INTO v_ant FROM proveedores p WHERE p.id = (v_item->>'proveedor_id')::uuid;
    PERFORM set_config('virikyna.suppress_audit', 'true', true);
    UPDATE proveedores p
    SET saldo_inicial = v_monto, saldo_inicial_fecha = now(), saldo_inicial_usuario_id = auth.uid()
    WHERE p.id = (v_item->>'proveedor_id')::uuid
    RETURNING to_jsonb(p) INTO v_nue;
    PERFORM set_config('virikyna.suppress_audit', 'false', true);
    INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, valores_nuevos, usuario_id, nota)
    VALUES ('proveedores', (v_item->>'proveedor_id')::uuid, 'edicion', v_ant, v_nue, auth.uid(),
            'Carga inicial: saldo inicial ' || formato_pesos(v_monto));
  END LOOP;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_clientes) LOOP
    v_monto := round((v_item->>'monto')::numeric, 2);
    SELECT to_jsonb(c) INTO v_ant FROM clientes c WHERE c.id = (v_item->>'cliente_id')::uuid;
    PERFORM set_config('virikyna.suppress_audit', 'true', true);
    UPDATE clientes c
    SET saldo_inicial = v_monto, saldo_inicial_fecha = now(), saldo_inicial_usuario_id = auth.uid()
    WHERE c.id = (v_item->>'cliente_id')::uuid
    RETURNING to_jsonb(c) INTO v_nue;
    PERFORM set_config('virikyna.suppress_audit', 'false', true);
    INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, valores_nuevos, usuario_id, nota)
    VALUES ('clientes', (v_item->>'cliente_id')::uuid, 'edicion', v_ant, v_nue, auth.uid(),
            'Carga inicial: saldo inicial ' || formato_pesos(v_monto));
  END LOOP;
END;
$$;
COMMENT ON FUNCTION public.cargar_saldos_iniciales(jsonb, jsonb, jsonb) IS 'docs/69: carga el saldo inicial de cuentas de dinero, proveedores y clientes que todavía no lo tienen. Único: si alguna ya lo tiene, rechaza todo nombrándolas. Solo admin.';
REVOKE ALL ON FUNCTION public.cargar_saldos_iniciales(jsonb, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cargar_saldos_iniciales(jsonb, jsonb, jsonb) TO authenticated, service_role;

-- ─── 6. corregir_saldo_inicial ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.corregir_saldo_inicial(p_tipo text, p_id uuid, p_monto_nuevo numeric, p_motivo text)
  RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_motivo text := btrim(COALESCE(p_motivo, ''));
  v_nuevo numeric := round(p_monto_nuevo, 2);
  v_tabla text;
  v_ant jsonb;
  v_nue jsonb;
  v_anterior numeric;
  v_fecha timestamptz;
  v_nombre text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede corregir un saldo inicial';
  END IF;
  IF p_tipo IS NULL OR p_tipo NOT IN ('proveedor', 'cliente') THEN
    RAISE EXCEPTION 'Tipo de cuenta no válido (proveedor o cliente)';
  END IF;
  IF v_nuevo IS NULL THEN
    RAISE EXCEPTION 'Ingresá el monto nuevo';
  END IF;
  IF length(v_motivo) < 3 THEN
    RAISE EXCEPTION 'Ingresá el motivo de la corrección';
  END IF;

  IF p_tipo = 'proveedor' THEN
    v_tabla := 'proveedores';
    SELECT to_jsonb(p), p.saldo_inicial, p.saldo_inicial_fecha, p.razon_social
    INTO v_ant, v_anterior, v_fecha, v_nombre
    FROM proveedores p WHERE p.id = p_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Proveedor no encontrado'; END IF;
  ELSE
    v_tabla := 'clientes';
    SELECT to_jsonb(c), c.saldo_inicial, c.saldo_inicial_fecha, COALESCE(c.razon_social, c.nombre_fantasia)
    INTO v_ant, v_anterior, v_fecha, v_nombre
    FROM clientes c WHERE c.id = p_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Cliente no encontrado'; END IF;
  END IF;

  IF v_anterior = 0 AND v_fecha IS NULL THEN
    RAISE EXCEPTION '% no tiene saldo inicial cargado: cargalo desde la carga inicial', v_nombre;
  END IF;
  IF v_nuevo = v_anterior THEN
    RAISE EXCEPTION 'El monto nuevo es igual al actual (%)', formato_pesos(v_anterior);
  END IF;

  PERFORM set_config('virikyna.suppress_audit', 'true', true);
  IF p_tipo = 'proveedor' THEN
    UPDATE proveedores p
    SET saldo_inicial = v_nuevo, saldo_inicial_fecha = now(), saldo_inicial_usuario_id = auth.uid()
    WHERE p.id = p_id
    RETURNING to_jsonb(p) INTO v_nue;
  ELSE
    UPDATE clientes c
    SET saldo_inicial = v_nuevo, saldo_inicial_fecha = now(), saldo_inicial_usuario_id = auth.uid()
    WHERE c.id = p_id
    RETURNING to_jsonb(c) INTO v_nue;
  END IF;
  PERFORM set_config('virikyna.suppress_audit', 'false', true);

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, valores_nuevos, usuario_id, nota)
  VALUES (v_tabla, p_id, 'edicion', v_ant, v_nue, auth.uid(),
          'Corrección de saldo inicial: ' || formato_pesos(v_anterior) || ' → ' || formato_pesos(v_nuevo) || '. Motivo: ' || v_motivo);

  RETURN jsonb_build_object('anterior', v_anterior, 'nuevo', v_nuevo);
END;
$$;
COMMENT ON FUNCTION public.corregir_saldo_inicial(text, uuid, numeric, text) IS 'docs/69: reemplaza (no suma) el saldo inicial de un proveedor o cliente que ya lo tiene. Solo admin, motivo obligatorio; queda en auditoria con el motivo.';
REVOKE ALL ON FUNCTION public.corregir_saldo_inicial(text, uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.corregir_saldo_inicial(text, uuid, numeric, text) TO authenticated, service_role;

-- ─── 7. revertir_edicion: el saldo inicial no se restaura desde el Historial ──────────────────
CREATE OR REPLACE FUNCTION public.revertir_edicion(p_auditoria_id uuid) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_auditoria auditoria%ROWTYPE;
  v_set_clause TEXT;
  -- docs/69: campos que solo cambian cargar_saldos_iniciales / corregir_saldo_inicial.
  v_campos_saldo CONSTANT text[] := ARRAY['saldo_inicial', 'saldo_inicial_fecha', 'saldo_inicial_usuario_id'];
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede revertir acciones';
  END IF;

  SELECT * INTO v_auditoria FROM auditoria WHERE id = p_auditoria_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Acción no encontrada'; END IF;
  IF v_auditoria.accion <> 'edicion' THEN RAISE EXCEPTION 'Esta acción no es una edición reversible'; END IF;
  IF v_auditoria.tabla_afectada NOT IN ('productos', 'proveedores', 'clientes') THEN
    RAISE EXCEPTION 'Este cambio no se revierte con revertir_edicion — usá la función específica de ese tipo';
  END IF;
  IF EXISTS (SELECT 1 FROM auditoria WHERE revierte_auditoria_id = p_auditoria_id) THEN
    RAISE EXCEPTION 'Esta acción ya fue revertida';
  END IF;

  -- Una edición que solo tocó el saldo inicial no se revierte acá (se corrige con motivo).
  IF v_auditoria.tabla_afectada IN ('proveedores', 'clientes')
     AND EXISTS (SELECT 1 FROM jsonb_each(v_auditoria.valores_anteriores) a
                 WHERE a.key = ANY(v_campos_saldo) AND a.value IS DISTINCT FROM v_auditoria.valores_nuevos->a.key)
     AND NOT EXISTS (SELECT 1 FROM jsonb_each(v_auditoria.valores_anteriores) a
                     WHERE a.key <> ALL(v_campos_saldo) AND a.key NOT IN ('id', 'created_at', 'updated_at')
                       AND a.value IS DISTINCT FROM v_auditoria.valores_nuevos->a.key) THEN
    RAISE EXCEPTION 'Este cambio es del saldo inicial: se corrige desde Caja Gestión → Carga inicial (Corregir), con motivo';
  END IF;

  SELECT string_agg(format('%I = %L', kv.key, kv.value), ', ')
  INTO v_set_clause
  FROM jsonb_each_text(v_auditoria.valores_anteriores) AS kv(key, value)
  WHERE kv.key NOT IN ('id', 'created_at', 'updated_at', 'precio_venta', 'precio_calculado')
    AND kv.key <> ALL(v_campos_saldo);

  IF v_set_clause IS NULL THEN RAISE EXCEPTION 'No hay valores anteriores para restaurar'; END IF;

  PERFORM set_config('virikyna.suppress_audit', 'true', true);
  EXECUTE format('UPDATE %I SET %s WHERE id = %L', v_auditoria.tabla_afectada, v_set_clause, v_auditoria.registro_id);
  IF v_auditoria.tabla_afectada = 'productos' THEN
    EXECUTE format('UPDATE productos SET updated_at = now() WHERE id = %L', v_auditoria.registro_id);
  END IF;
  PERFORM set_config('virikyna.suppress_audit', 'false', true);

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, valores_nuevos, usuario_id, revierte_auditoria_id)
  VALUES (v_auditoria.tabla_afectada, v_auditoria.registro_id, 'reversion',
          v_auditoria.valores_nuevos, v_auditoria.valores_anteriores, auth.uid(), p_auditoria_id);
END;
$$;

-- ─── 8. Vistas: "a cuenta" que primero cancela el saldo inicial ──────────────────────────────
-- Por pago: los pagos sin comprobante, del más viejo al más nuevo (mismo orden que
-- aplicar_pagos_a_cuenta), cancelan primero el saldo inicial positivo del proveedor.
CREATE OR REPLACE VIEW public.pagos_proveedor_a_cuenta WITH (security_invoker = on) AS
SELECT b.id, b.proveedor_id, b.fecha, b.created_at, b.monto, b.aplicado, b.vigente, b.a_cuenta,
       b.a_cuenta - b.a_cuenta_libre AS cancela_saldo_inicial,
       b.a_cuenta_libre
FROM (
  SELECT x.*,
         GREATEST(0::numeric, LEAST(x.a_cuenta,
           SUM(GREATEST(x.a_cuenta, 0)) OVER (PARTITION BY x.proveedor_id ORDER BY x.fecha, x.created_at, x.id)
           - GREATEST(p.saldo_inicial, 0))) AS a_cuenta_libre
  FROM (
    SELECT pp.id, pp.proveedor_id, pp.fecha, pp.created_at, pp.monto, ap.aplicado, v.vigente,
           CASE WHEN v.vigente THEN pp.monto - ap.aplicado ELSE 0::numeric END AS a_cuenta
    FROM pagos_proveedor pp
    CROSS JOIN LATERAL (
      SELECT COALESCE(SUM(a.monto), 0::numeric) AS aplicado FROM pagos_proveedor_aplicaciones a
      WHERE a.pago_proveedor_id = pp.id AND a.revertida_at IS NULL
    ) ap
    CROSS JOIN LATERAL (
      SELECT pp.monto > 0 AND pp.revierte_pago_proveedor_id IS NULL
             AND NOT EXISTS (SELECT 1 FROM pagos_proveedor r WHERE r.revierte_pago_proveedor_id = pp.id) AS vigente
    ) v
  ) x
  JOIN proveedores p ON p.id = x.proveedor_id
) b;
COMMENT ON VIEW public.pagos_proveedor_a_cuenta IS 'docs/52 + docs/69: por pago, lo aplicado vigente y lo que queda a cuenta (0 en reversiones, revertidos y operaciones solo de NC). cancela_saldo_inicial = parte que cancela el saldo inicial (pagos más viejos primero); a_cuenta_libre = lo que se puede aplicar a comprobantes.';

CREATE OR REPLACE VIEW public.proveedores_a_cuenta WITH (security_invoker = on) AS
SELECT proveedor_id,
       sum(a_cuenta) AS a_cuenta,
       count(*) FILTER (WHERE a_cuenta > 0) AS pagos_con_saldo,
       sum(a_cuenta_libre) AS a_cuenta_libre
FROM pagos_proveedor_a_cuenta
GROUP BY proveedor_id;
COMMENT ON VIEW public.proveedores_a_cuenta IS 'docs/52 + docs/69: total a cuenta (pagos sin aplicar) por proveedor; a_cuenta_libre descuenta lo que cancela el saldo inicial.';

CREATE OR REPLACE VIEW public.proveedores_saldo WITH (security_invoker = on) AS
SELECT p.id, p.razon_social, p.cuit, p.direccion, p.telefono, p.mail, p.contacto,
       p.margen_1_default, p.margen_2_default, p.saldo_inicial, p.created_at,
       p.saldo_inicial + COALESCE(facturado.total_facturado, 0::numeric) - COALESCE(pagado.total_pagado, 0::numeric) AS saldo_actual,
       p.observaciones,
       p.saldo_inicial_fecha,
       p.saldo_inicial_usuario_id,
       u.nombre AS saldo_inicial_usuario_nombre,
       p.saldo_inicial - COALESCE(ac.a_cuenta - ac.a_cuenta_libre, 0::numeric) AS saldo_inicial_pendiente,
       COALESCE(ac.a_cuenta_libre, 0::numeric) AS a_cuenta_libre
FROM proveedores p
LEFT JOIN (
  SELECT facturas_compra.proveedor_id,
         sum(CASE WHEN facturas_compra.tipo_comprobante = 'nota_credito'::tipo_comprobante_compra
                  THEN - facturas_compra.total ELSE facturas_compra.total END) AS total_facturado
  FROM facturas_compra
  WHERE facturas_compra.anulada = false
  GROUP BY facturas_compra.proveedor_id
) facturado ON facturado.proveedor_id = p.id
LEFT JOIN (
  SELECT pagos_proveedor.proveedor_id, sum(pagos_proveedor.monto) AS total_pagado
  FROM pagos_proveedor
  GROUP BY pagos_proveedor.proveedor_id
) pagado ON pagado.proveedor_id = p.id
LEFT JOIN proveedores_a_cuenta ac ON ac.proveedor_id = p.id
-- perfiles tiene RLS "solo el propio": el nombre sale de perfiles_publico (vista definer, activos).
LEFT JOIN perfiles_publico u ON u.id = p.saldo_inicial_usuario_id;

-- Clientes: misma lógica sobre los cobros (docs/68).
CREATE OR REPLACE VIEW public.pagos_cliente_a_cuenta WITH (security_invoker = on) AS
SELECT b.id, b.cliente_id, b.fecha, b.created_at, b.monto, b.origen, b.aplicado, b.vigente, b.a_cuenta,
       b.a_cuenta - b.a_cuenta_libre AS cancela_saldo_inicial,
       b.a_cuenta_libre
FROM (
  SELECT x.*,
         GREATEST(0::numeric, LEAST(x.a_cuenta,
           SUM(GREATEST(x.a_cuenta, 0)) OVER (PARTITION BY x.cliente_id ORDER BY x.fecha, x.created_at, x.id)
           - GREATEST(c.saldo_inicial, 0))) AS a_cuenta_libre
  FROM (
    SELECT pc.id, pc.cliente_id, pc.fecha, pc.created_at, pc.monto, pc.origen, ap.aplicado, v.vigente,
           CASE WHEN v.vigente THEN pc.monto - ap.aplicado ELSE 0 END AS a_cuenta
    FROM pagos_cliente pc
    CROSS JOIN LATERAL (
      SELECT COALESCE(SUM(a.monto), 0) AS aplicado FROM pagos_cliente_aplicaciones a
      WHERE a.pago_cliente_id = pc.id AND a.revertida_at IS NULL
    ) ap
    CROSS JOIN LATERAL (
      SELECT pc.monto > 0 AND pc.revierte_pago_cliente_id IS NULL
             AND NOT EXISTS (SELECT 1 FROM pagos_cliente r WHERE r.revierte_pago_cliente_id = pc.id) AS vigente
    ) v
  ) x
  JOIN clientes c ON c.id = x.cliente_id
) b;
COMMENT ON VIEW public.pagos_cliente_a_cuenta IS 'docs/68 + docs/69: por cobro, lo aplicado vigente y lo que queda a cuenta (0 en reversiones y revertidos). cancela_saldo_inicial = parte que cancela el saldo inicial (cobros más viejos primero); a_cuenta_libre = lo que se puede aplicar a ventas.';

CREATE OR REPLACE VIEW public.clientes_saldo WITH (security_invoker = on) AS
SELECT c.id, c.razon_social, c.nombre_fantasia, c.cuit, c.domicilio, c.mail, c.celular, c.activo,
       c.saldo_inicial, c.created_at,
       c.saldo_inicial + COALESCE(vt.neto, 0) - COALESCE(pg.total_pagado, 0) AS saldo_actual,
       c.condicion_iva, c.tipo, c.perfil_id,
       COALESCE(vt.deuda_comprobantes, 0) AS deuda_comprobantes,
       COALESCE(vt.interno_pendiente, 0) AS consumo_interno_pendiente,
       COALESCE(ac.a_cuenta, 0) AS a_cuenta,
       c.saldo_inicial + COALESCE(vt.neto, 0) - COALESCE(vt.interno_pendiente, 0) - COALESCE(pg.total_pagado, 0) AS saldo_cobrable,
       COALESCE(vt.comprobantes_abiertos, 0) AS comprobantes_abiertos,
       c.saldo_inicial_fecha,
       c.saldo_inicial_usuario_id,
       u.nombre AS saldo_inicial_usuario_nombre,
       c.saldo_inicial - COALESCE(ac.a_cuenta - ac.a_cuenta_libre, 0) AS saldo_inicial_pendiente,
       COALESCE(ac.a_cuenta_libre, 0) AS a_cuenta_libre
FROM clientes c
LEFT JOIN (
  SELECT s.cliente_id,
         SUM(s.total - s.total_devuelto) FILTER (WHERE s.estado_interno IS DISTINCT FROM 'finalizado') AS neto,
         SUM(s.saldo_pendiente) FILTER (WHERE s.estado_interno IS NULL) AS deuda_comprobantes,
         SUM(s.total - s.total_devuelto) FILTER (WHERE s.estado_interno = 'pendiente') AS interno_pendiente,
         COUNT(*) FILTER (WHERE s.estado_cuenta IN ('pendiente', 'parcial', 'a_revisar')) AS comprobantes_abiertos
  FROM ventas_cuenta_corriente_saldo s
  WHERE s.estado <> 'anulada'
  GROUP BY s.cliente_id
) vt ON vt.cliente_id = c.id
LEFT JOIN (SELECT cliente_id, SUM(monto) AS total_pagado FROM pagos_cliente GROUP BY cliente_id) pg ON pg.cliente_id = c.id
LEFT JOIN (SELECT cliente_id, SUM(a_cuenta) AS a_cuenta, SUM(a_cuenta_libre) AS a_cuenta_libre
           FROM pagos_cliente_a_cuenta GROUP BY cliente_id) ac ON ac.cliente_id = c.id
LEFT JOIN perfiles_publico u ON u.id = c.saldo_inicial_usuario_id;
COMMENT ON VIEW public.clientes_saldo IS 'docs/68 + docs/69: saldo de cuenta corriente por cliente. saldo_actual excluye internas finalizadas y descuenta devoluciones imputadas; saldo_cobrable además excluye internas pendientes. saldo_inicial_pendiente / a_cuenta_libre: los cobros sin venta cancelan primero el saldo inicial.';

-- Permisos (CREATE OR REPLACE los conserva; se repiten por si la vista se recrea).
REVOKE ALL ON public.pagos_proveedor_a_cuenta, public.proveedores_a_cuenta, public.proveedores_saldo,
              public.pagos_cliente_a_cuenta, public.clientes_saldo
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.pagos_proveedor_a_cuenta, public.proveedores_a_cuenta, public.proveedores_saldo,
               public.pagos_cliente_a_cuenta, public.clientes_saldo
  TO authenticated, service_role;

-- ─── 9. Aplicar pagos / cobros a cuenta: solo lo libre ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.aplicar_pagos_a_cuenta(p_proveedor_id uuid, p_factura_ids uuid[] DEFAULT NULL::uuid[], p_pago_ids uuid[] DEFAULT NULL::uuid[])
  RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_factura_ids UUID[];
  v_pago_ids UUID[];
  v_mal facturas_compra%ROWTYPE;
  v_pago_mal RECORD;
  v_doc_ids UUID[] := '{}';
  v_doc_saldos NUMERIC[] := '{}';
  v_pag_ids UUID[] := '{}';
  v_pag_disp NUMERIC[] := '{}';
  v_n INT;
  v_m INT;
  i INT := 1;
  j INT := 1;
  v_aplicar NUMERIC;
  v_total NUMERIC := 0;
  v_ids UUID[] := '{}';
  v_id UUID;
BEGIN
  -- Mismo permiso que registrar_pago_proveedor_v2: cualquier perfil activo. No mueve plata.
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  SELECT array_agg(DISTINCT x) INTO v_factura_ids FROM unnest(p_factura_ids) AS x WHERE x IS NOT NULL;
  SELECT array_agg(DISTINCT x) INTO v_pago_ids FROM unnest(p_pago_ids) AS x WHERE x IS NOT NULL;

  -- Mismo lock que v2: serializa pagos, aplicaciones y quitas del mismo proveedor.
  PERFORM 1 FROM proveedores WHERE id = p_proveedor_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Proveedor no encontrado';
  END IF;

  -- ── Comprobantes elegidos: mismas reglas que v2 ──
  IF v_factura_ids IS NOT NULL THEN
    IF (SELECT count(*) FROM facturas_compra WHERE id = ANY(v_factura_ids)) <> cardinality(v_factura_ids) THEN
      RAISE EXCEPTION 'Alguno de los comprobantes elegidos no existe';
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_factura_ids) AND proveedor_id <> p_proveedor_id LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El comprobante % no es de este proveedor', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_factura_ids) AND anulada LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El comprobante % está anulado, no se le aplican pagos', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_factura_ids) AND tipo_comprobante = 'nota_credito' LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El comprobante % es una nota de crédito: no se le aplican pagos', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
  END IF;

  -- ── Pagos elegidos: del proveedor y vigentes ──
  IF v_pago_ids IS NOT NULL THEN
    IF (SELECT count(*) FROM pagos_proveedor WHERE id = ANY(v_pago_ids)) <> cardinality(v_pago_ids) THEN
      RAISE EXCEPTION 'Alguno de los pagos elegidos no existe';
    END IF;
    SELECT * INTO v_pago_mal FROM pagos_proveedor_a_cuenta WHERE id = ANY(v_pago_ids) AND proveedor_id <> p_proveedor_id LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El pago del % no es de este proveedor', to_char(v_pago_mal.fecha, 'DD/MM/YYYY');
    END IF;
    SELECT * INTO v_pago_mal FROM pagos_proveedor_a_cuenta WHERE id = ANY(v_pago_ids) AND NOT vigente LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El pago del % no está vigente (fue revertido o es una reversión)', to_char(v_pago_mal.fecha, 'DD/MM/YYYY');
    END IF;
  END IF;

  -- ── Comprobantes a cancelar, más viejos primero (mismo orden y saldo que v2) ──
  SELECT COALESCE(array_agg(d.id ORDER BY d.fecha_comprobante, d.created_at, d.id), '{}'),
         COALESCE(array_agg(d.saldo ORDER BY d.fecha_comprobante, d.created_at, d.id), '{}')
  INTO v_doc_ids, v_doc_saldos
  FROM (
    SELECT fc.id, fc.fecha_comprobante, fc.created_at,
           fc.total - COALESCE((SELECT SUM(a.monto) FROM pagos_proveedor_aplicaciones a
                                WHERE a.factura_compra_id = fc.id AND a.revertida_at IS NULL), 0) AS saldo
    FROM facturas_compra fc
    WHERE fc.proveedor_id = p_proveedor_id
      AND NOT fc.anulada
      AND fc.tipo_comprobante <> 'nota_credito'
      AND (v_factura_ids IS NULL OR fc.id = ANY(v_factura_ids))
  ) d
  WHERE d.saldo > 0;
  v_n := cardinality(v_doc_ids);

  IF v_n = 0 THEN
    RAISE EXCEPTION 'No hay saldo pendiente en los comprobantes al que aplicar el pago a cuenta';
  END IF;

  -- ── Pagos con saldo a cuenta LIBRE (docs/69: lo que cancela el saldo inicial no se aplica) ──
  SELECT COALESCE(array_agg(p.id ORDER BY p.fecha, p.created_at, p.id), '{}'),
         COALESCE(array_agg(p.a_cuenta_libre ORDER BY p.fecha, p.created_at, p.id), '{}')
  INTO v_pag_ids, v_pag_disp
  FROM pagos_proveedor_a_cuenta p
  WHERE p.proveedor_id = p_proveedor_id
    AND p.a_cuenta_libre > 0
    AND (v_pago_ids IS NULL OR p.id = ANY(v_pago_ids));
  v_m := cardinality(v_pag_ids);

  IF v_m = 0 THEN
    IF EXISTS (SELECT 1 FROM pagos_proveedor_a_cuenta p
               WHERE p.proveedor_id = p_proveedor_id AND p.a_cuenta > 0
                 AND (v_pago_ids IS NULL OR p.id = ANY(v_pago_ids))) THEN
      RAISE EXCEPTION 'Los pagos a cuenta de este proveedor cancelan su saldo inicial: no queda nada para aplicar a comprobantes';
    END IF;
    RAISE EXCEPTION 'Este proveedor no tiene pagos a cuenta para aplicar';
  END IF;

  -- ── Reparto: pago más viejo contra comprobante más viejo ──
  WHILE i <= v_n AND j <= v_m LOOP
    v_aplicar := LEAST(v_doc_saldos[i], v_pag_disp[j]);
    INSERT INTO pagos_proveedor_aplicaciones
      (factura_compra_id, monto, pago_proveedor_id, nota_credito_id, operacion_id, usuario_id)
    VALUES (v_doc_ids[i], v_aplicar, v_pag_ids[j], NULL, v_pag_ids[j], auth.uid())
    RETURNING id INTO v_id;
    v_ids := array_append(v_ids, v_id);
    v_total := v_total + v_aplicar;
    v_doc_saldos[i] := v_doc_saldos[i] - v_aplicar;
    v_pag_disp[j] := v_pag_disp[j] - v_aplicar;
    IF v_doc_saldos[i] <= 0 THEN i := i + 1; END IF;
    IF v_pag_disp[j] <= 0 THEN j := j + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'aplicado', v_total,
    'a_cuenta_restante', (SELECT COALESCE(SUM(a_cuenta_libre), 0) FROM pagos_proveedor_a_cuenta WHERE proveedor_id = p_proveedor_id),
    'aplicaciones', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', a.id,
               'pago_proveedor_id', a.pago_proveedor_id,
               'factura_compra_id', a.factura_compra_id,
               'monto', a.monto
             -- En el orden en que se aplicaron: created_at es el mismo para toda la transacción.
             ) ORDER BY array_position(v_ids, a.id))
      FROM pagos_proveedor_aplicaciones a
      WHERE a.id = ANY(v_ids)
    ), '[]'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.aplicar_cobros_a_cuenta(p_cliente_id uuid, p_venta_ids uuid[] DEFAULT NULL::uuid[], p_pago_ids uuid[] DEFAULT NULL::uuid[])
  RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_venta_ids UUID[];
  v_pago_ids UUID[];
  v_mal RECORD;
  v_doc_ids UUID[] := '{}';
  v_doc_saldos NUMERIC[] := '{}';
  v_pag_ids UUID[] := '{}';
  v_pag_disp NUMERIC[] := '{}';
  i INT := 1;
  j INT := 1;
  v_aplicar NUMERIC;
  v_total NUMERIC := 0;
  v_ids UUID[] := '{}';
  v_id UUID;
BEGIN
  -- Mismo permiso que cobrar: cualquier perfil activo. No mueve plata.
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  SELECT array_agg(DISTINCT x) INTO v_venta_ids FROM unnest(p_venta_ids) AS x WHERE x IS NOT NULL;
  SELECT array_agg(DISTINCT x) INTO v_pago_ids FROM unnest(p_pago_ids) AS x WHERE x IS NOT NULL;

  PERFORM 1 FROM clientes WHERE id = p_cliente_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Cliente no encontrado'; END IF;

  IF v_venta_ids IS NOT NULL THEN
    IF (SELECT count(*) FROM ventas WHERE id = ANY(v_venta_ids)) <> cardinality(v_venta_ids) THEN
      RAISE EXCEPTION 'Alguna de las ventas elegidas no existe';
    END IF;
    SELECT numero INTO v_mal FROM ventas WHERE id = ANY(v_venta_ids) AND cliente_id IS DISTINCT FROM p_cliente_id LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'La venta N° % no es de este cliente', v_mal.numero; END IF;
    SELECT numero INTO v_mal FROM ventas WHERE id = ANY(v_venta_ids)
      AND (forma_pago <> 'cuenta_corriente' OR estado = 'anulada' OR estado_interno IS NOT NULL) LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'A la venta N° % no se le aplican cobros', v_mal.numero; END IF;
  END IF;
  IF v_pago_ids IS NOT NULL THEN
    IF (SELECT count(*) FROM pagos_cliente WHERE id = ANY(v_pago_ids)) <> cardinality(v_pago_ids) THEN
      RAISE EXCEPTION 'Alguno de los cobros elegidos no existe';
    END IF;
    SELECT * INTO v_mal FROM pagos_cliente_a_cuenta WHERE id = ANY(v_pago_ids) AND cliente_id <> p_cliente_id LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'El cobro del % no es de este cliente', to_char(v_mal.fecha, 'DD/MM/YYYY'); END IF;
    SELECT * INTO v_mal FROM pagos_cliente_a_cuenta WHERE id = ANY(v_pago_ids) AND NOT vigente LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'El cobro del % no está vigente (fue revertido o es una reversión)', to_char(v_mal.fecha, 'DD/MM/YYYY'); END IF;
  END IF;

  SELECT COALESCE(array_agg(s.id ORDER BY s.created_at, s.id), '{}'),
         COALESCE(array_agg(s.saldo_pendiente ORDER BY s.created_at, s.id), '{}')
  INTO v_doc_ids, v_doc_saldos
  FROM ventas_cuenta_corriente_saldo s
  WHERE s.cliente_id = p_cliente_id AND s.estado <> 'anulada' AND s.estado_interno IS NULL
    AND s.saldo_pendiente > 0 AND (v_venta_ids IS NULL OR s.id = ANY(v_venta_ids));
  IF cardinality(v_doc_ids) = 0 THEN
    RAISE EXCEPTION 'No hay saldo pendiente en las ventas al que aplicar el cobro a cuenta';
  END IF;

  -- docs/69: solo lo libre (lo que cancela el saldo inicial no se aplica a ventas).
  SELECT COALESCE(array_agg(p.id ORDER BY p.fecha, p.created_at, p.id), '{}'),
         COALESCE(array_agg(p.a_cuenta_libre ORDER BY p.fecha, p.created_at, p.id), '{}')
  INTO v_pag_ids, v_pag_disp
  FROM pagos_cliente_a_cuenta p
  WHERE p.cliente_id = p_cliente_id AND p.a_cuenta_libre > 0 AND (v_pago_ids IS NULL OR p.id = ANY(v_pago_ids));
  IF cardinality(v_pag_ids) = 0 THEN
    IF EXISTS (SELECT 1 FROM pagos_cliente_a_cuenta p
               WHERE p.cliente_id = p_cliente_id AND p.a_cuenta > 0 AND (v_pago_ids IS NULL OR p.id = ANY(v_pago_ids))) THEN
      RAISE EXCEPTION 'Los cobros a cuenta de este cliente cancelan su saldo inicial: no queda nada para aplicar a ventas';
    END IF;
    RAISE EXCEPTION 'Este cliente no tiene cobros a cuenta para aplicar';
  END IF;

  WHILE i <= cardinality(v_doc_ids) AND j <= cardinality(v_pag_ids) LOOP
    v_aplicar := LEAST(v_doc_saldos[i], v_pag_disp[j]);
    INSERT INTO pagos_cliente_aplicaciones (pago_cliente_id, venta_id, monto, operacion_id, usuario_id)
    VALUES (v_pag_ids[j], v_doc_ids[i], v_aplicar, v_pag_ids[j], auth.uid())
    RETURNING id INTO v_id;
    v_ids := array_append(v_ids, v_id);
    v_total := v_total + v_aplicar;
    v_doc_saldos[i] := v_doc_saldos[i] - v_aplicar;
    v_pag_disp[j] := v_pag_disp[j] - v_aplicar;
    IF v_doc_saldos[i] <= 0 THEN i := i + 1; END IF;
    IF v_pag_disp[j] <= 0 THEN j := j + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'aplicado', v_total,
    'a_cuenta_restante', (SELECT COALESCE(SUM(a_cuenta_libre), 0) FROM pagos_cliente_a_cuenta WHERE cliente_id = p_cliente_id),
    'aplicaciones', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', a.id, 'pago_cliente_id', a.pago_cliente_id, 'venta_id', a.venta_id, 'monto', a.monto)
                       ORDER BY array_position(v_ids, a.id))
      FROM pagos_cliente_aplicaciones a WHERE a.id = ANY(v_ids)
    ), '[]'::jsonb)
  );
END;
$$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lectura)
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- B1. Saldos iniciales con fecha y usuario (esperado: GUTIERREZ, TOYCO, LUX ATLANTIC — Alicia).
SELECT 'proveedor' AS tipo, p.razon_social AS nombre, p.saldo_inicial,
       to_char(p.saldo_inicial_fecha AT TIME ZONE 'America/Argentina/Buenos_Aires', 'YYYY-MM-DD HH24:MI') AS fecha_ar,
       pf.nombre AS usuario, ps.saldo_inicial_pendiente, ps.a_cuenta_libre, ps.saldo_actual
FROM proveedores p
JOIN proveedores_saldo ps ON ps.id = p.id
LEFT JOIN perfiles pf ON pf.id = p.saldo_inicial_usuario_id
WHERE p.saldo_inicial <> 0 OR p.saldo_inicial_fecha IS NOT NULL
UNION ALL
SELECT 'cliente', COALESCE(c.razon_social, c.nombre_fantasia), c.saldo_inicial,
       to_char(c.saldo_inicial_fecha AT TIME ZONE 'America/Argentina/Buenos_Aires', 'YYYY-MM-DD HH24:MI'),
       pf.nombre, cs.saldo_inicial_pendiente, cs.a_cuenta_libre, cs.saldo_actual
FROM clientes c
JOIN clientes_saldo cs ON cs.id = c.id
LEFT JOIN perfiles pf ON pf.id = c.saldo_inicial_usuario_id
WHERE c.saldo_inicial <> 0 OR c.saldo_inicial_fecha IS NOT NULL
ORDER BY 1, 2;

-- B2. Identidad por proveedor (esperado: 0 filas).
--     saldo_actual = saldo_inicial_pendiente + Σ saldo_pendiente − Σ crédito NC − a_cuenta_libre
SELECT ps.razon_social, ps.saldo_actual,
       ps.saldo_inicial_pendiente + COALESCE(d.pend, 0) - COALESCE(d.cred, 0) - ps.a_cuenta_libre AS reconstruido
FROM proveedores_saldo ps
LEFT JOIN (
  SELECT proveedor_id, SUM(saldo_pendiente) FILTER (WHERE NOT anulada) AS pend,
         SUM(credito_disponible) FILTER (WHERE NOT anulada) AS cred
  FROM facturas_compra_saldo GROUP BY proveedor_id
) d ON d.proveedor_id = ps.id
WHERE ps.saldo_actual IS DISTINCT FROM ps.saldo_inicial_pendiente + COALESCE(d.pend, 0) - COALESCE(d.cred, 0) - ps.a_cuenta_libre;

-- B3. security_invoker en las vistas tocadas (esperado: las 5 con security_invoker=on).
SELECT c.relname, c.reloptions FROM pg_class c
WHERE c.relname IN ('pagos_proveedor_a_cuenta', 'proveedores_a_cuenta', 'proveedores_saldo', 'pagos_cliente_a_cuenta', 'clientes_saldo')
ORDER BY 1;

-- B4. UPDATE/DELETE sin WHERE en las funciones tocadas (safeupdate; esperado: 0 filas).
SELECT p.proname FROM pg_proc p
WHERE p.proname IN ('cargar_saldos_iniciales', 'corregir_saldo_inicial', 'revertir_edicion', 'aplicar_pagos_a_cuenta', 'aplicar_cobros_a_cuenta')
  AND p.prosrc ~* '(UPDATE\s+\w+(\s+\w+)?\s+SET[^;]*;)' AND p.prosrc !~* 'WHERE';

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — tests (BEGIN … ROLLBACK). Corre como Alicia (admin) y como "Cajero de prueba".
-- Termina SIEMPRE con RAISE EXCEPTION 'RESULTADO: …' (la transacción aborta y no queda nada).
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
  c_alicia CONSTANT uuid := '696bd7fb-aa27-4051-b8cd-d611ee90d1ae';
  c_cajero CONSTANT uuid := 'c982462a-526a-4ee7-aade-4488b74966b3';
  v_gut uuid; v_toy uuid; v_lux uuid;
  v_prov uuid; v_cli uuid; v_fac uuid; v_pago uuid; v_aud uuid;
  v_msg text;
  v_ok text[] := '{}';
  r RECORD;
  v_n int;
BEGIN
  SELECT id INTO v_gut FROM proveedores WHERE razon_social LIKE 'GUTIERREZ LEANDRO%';
  SELECT id INTO v_toy FROM proveedores WHERE razon_social LIKE 'THE TOY COMPANY%';
  SELECT id INTO v_lux FROM proveedores WHERE razon_social LIKE 'LUX ATLANTIC%';

  -- T1. Backfill: los 3 con fecha = la del UPDATE de auditoria y usuario Alicia.
  SELECT count(*) INTO v_n FROM proveedores
  WHERE id IN (v_gut, v_toy, v_lux) AND saldo_inicial_usuario_id = c_alicia AND saldo_inicial_fecha IS NOT NULL;
  IF v_n <> 3 THEN RAISE EXCEPTION 'T1: backfill incompleto (% de 3)', v_n; END IF;
  IF (SELECT to_char(saldo_inicial_fecha AT TIME ZONE 'America/Argentina/Buenos_Aires', 'YYYY-MM-DD HH24:MI') FROM proveedores WHERE id = v_gut) <> '2026-10-20 09:32' THEN
    RAISE EXCEPTION 'T1: fecha de GUTIERREZ distinta de la auditoría';
  END IF;
  v_ok := array_append(v_ok, 'T1');

  -- T2. Vistas: saldo inicial pendiente 0, a cuenta libre 0 (LUX 0,02 = el −0,02 a favor).
  SELECT * INTO r FROM proveedores_saldo WHERE id = v_gut;
  IF r.saldo_inicial_pendiente <> 0 OR r.a_cuenta_libre <> 0 OR r.saldo_actual <> 0 THEN RAISE EXCEPTION 'T2 GUT: % / % / %', r.saldo_inicial_pendiente, r.a_cuenta_libre, r.saldo_actual; END IF;
  SELECT * INTO r FROM proveedores_saldo WHERE id = v_toy;
  IF r.saldo_inicial_pendiente <> 0 OR r.a_cuenta_libre <> 0 OR r.saldo_actual <> 0 THEN RAISE EXCEPTION 'T2 TOY: % / % / %', r.saldo_inicial_pendiente, r.a_cuenta_libre, r.saldo_actual; END IF;
  SELECT * INTO r FROM proveedores_saldo WHERE id = v_lux;
  IF r.saldo_inicial_pendiente <> 0 OR r.a_cuenta_libre <> 0.02 OR r.saldo_actual <> -0.02 THEN RAISE EXCEPTION 'T2 LUX: % / % / %', r.saldo_inicial_pendiente, r.a_cuenta_libre, r.saldo_actual; END IF;
  IF (SELECT saldo_inicial_usuario_nombre FROM proveedores_saldo WHERE id = v_gut) <> 'Alicia' THEN RAISE EXCEPTION 'T2: nombre de usuario'; END IF;
  v_ok := array_append(v_ok, 'T2');

  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_alicia, 'role', 'authenticated')::text, true);

  -- T3. Cargar de nuevo GUTIERREZ (y TOYCO): rechaza todo, nombra a los dos, no suma.
  BEGIN
    PERFORM cargar_saldos_iniciales('[]', jsonb_build_array(jsonb_build_object('proveedor_id', v_gut, 'monto', 500),
                                                            jsonb_build_object('proveedor_id', v_toy, 'monto', 100)), '[]');
    RAISE EXCEPTION 'T3: debía fallar';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE '%GUTIERREZ LEANDRO%$ 1.972.962,10%' OR v_msg NOT LIKE '%THE TOY COMPANY%' OR v_msg LIKE 'T3:%' THEN
      RAISE EXCEPTION 'T3: mensaje inesperado: %', v_msg;
    END IF;
  END;
  IF (SELECT saldo_inicial FROM proveedores WHERE id = v_gut) <> 1972962.10 THEN RAISE EXCEPTION 'T3: sumó'; END IF;
  v_ok := array_append(v_ok, 'T3');

  -- T4. Proveedor nuevo: la carga setea fecha y usuario y deja UNA fila de auditoria con nota.
  SET LOCAL virikyna.suppress_audit = 'false';
  INSERT INTO proveedores (razon_social) VALUES ('ZZ TEST DOCS69') RETURNING id INTO v_prov;
  PERFORM cargar_saldos_iniciales('[]', jsonb_build_array(jsonb_build_object('proveedor_id', v_prov, 'monto', 1000.555)), '[]');
  SELECT * INTO r FROM proveedores WHERE id = v_prov;
  IF r.saldo_inicial <> 1000.56 OR r.saldo_inicial_usuario_id <> c_alicia OR r.saldo_inicial_fecha IS NULL THEN RAISE EXCEPTION 'T4: %', row_to_json(r); END IF;
  SELECT count(*) INTO v_n FROM auditoria WHERE registro_id = v_prov AND accion = 'edicion';
  IF v_n <> 1 OR NOT EXISTS (SELECT 1 FROM auditoria WHERE registro_id = v_prov AND nota = 'Carga inicial: saldo inicial $ 1.000,56') THEN
    RAISE EXCEPTION 'T4: auditoria (% filas)', v_n;
  END IF;
  v_ok := array_append(v_ok, 'T4');

  -- T5. Cajero: no puede tocar el saldo inicial; sí el resto de la ficha; no puede corregir.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_cajero, 'role', 'authenticated')::text, true);
  BEGIN
    UPDATE proveedores SET saldo_inicial = 5 WHERE id = v_prov;
    RAISE EXCEPTION 'T5: el cajero cambió el saldo inicial';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE 'Solo un administrador%' THEN RAISE EXCEPTION 'T5a: %', v_msg; END IF;
  END;
  BEGIN
    UPDATE proveedores SET saldo_inicial_fecha = now() - interval '1 day' WHERE id = v_prov;
    RAISE EXCEPTION 'T5: el cajero cambió la fecha';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE 'Solo un administrador%' THEN RAISE EXCEPTION 'T5b: %', v_msg; END IF;
  END;
  BEGIN
    INSERT INTO clientes (razon_social, saldo_inicial) VALUES ('ZZ CAJERO', 10);
    RAISE EXCEPTION 'T5: el cajero dio de alta con saldo inicial';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE 'Solo un administrador%' THEN RAISE EXCEPTION 'T5c: %', v_msg; END IF;
  END;
  UPDATE proveedores SET telefono = '1234' WHERE id = v_prov;  -- el formulario de edición sigue andando
  BEGIN
    PERFORM corregir_saldo_inicial('proveedor', v_prov, 10, 'prueba');
    RAISE EXCEPTION 'T5: el cajero corrigió';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE 'Solo un administrador%' THEN RAISE EXCEPTION 'T5d: %', v_msg; END IF;
  END;
  v_ok := array_append(v_ok, 'T5');

  -- T6. Corregir (admin): motivo obligatorio, igual al actual rechaza, reemplaza (no suma).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_alicia, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM corregir_saldo_inicial('proveedor', v_gut, 2000000, '  ');
    RAISE EXCEPTION 'T6: sin motivo pasó';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg <> 'Ingresá el motivo de la corrección' THEN RAISE EXCEPTION 'T6a: %', v_msg; END IF;
  END;
  BEGIN
    PERFORM corregir_saldo_inicial('proveedor', v_gut, 1972962.10, 'igual');
    RAISE EXCEPTION 'T6: igual pasó';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE 'El monto nuevo es igual al actual%' THEN RAISE EXCEPTION 'T6b: %', v_msg; END IF;
  END;
  BEGIN
    PERFORM corregir_saldo_inicial('cliente', v_gut, 10, 'no existe');
    RAISE EXCEPTION 'T6: tipo cruzado pasó';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg <> 'Cliente no encontrado' THEN RAISE EXCEPTION 'T6c: %', v_msg; END IF;
  END;
  PERFORM corregir_saldo_inicial('proveedor', v_gut, 2000000, 'Faltaba una factura de octubre');
  SELECT * INTO r FROM proveedores_saldo WHERE id = v_gut;
  IF r.saldo_inicial <> 2000000 OR r.saldo_inicial_pendiente <> 27037.90 OR r.a_cuenta_libre <> 0 OR r.saldo_actual <> 27037.90 THEN
    RAISE EXCEPTION 'T6: % / % / % / %', r.saldo_inicial, r.saldo_inicial_pendiente, r.a_cuenta_libre, r.saldo_actual;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auditoria WHERE registro_id = v_gut AND nota = 'Corrección de saldo inicial: $ 1.972.962,10 → $ 2.000.000,00. Motivo: Faltaba una factura de octubre') THEN
    RAISE EXCEPTION 'T6: auditoria sin motivo';
  END IF;
  -- Bajar el saldo inicial por debajo de lo pagado: lo que sobra queda libre.
  PERFORM corregir_saldo_inicial('proveedor', v_gut, 1900000, 'Probando que libere');
  SELECT * INTO r FROM proveedores_saldo WHERE id = v_gut;
  IF r.saldo_inicial_pendiente <> 0 OR r.a_cuenta_libre <> 72962.10 OR r.saldo_actual <> -72962.10 THEN
    RAISE EXCEPTION 'T6 libera: % / % / %', r.saldo_inicial_pendiente, r.a_cuenta_libre, r.saldo_actual;
  END IF;
  PERFORM corregir_saldo_inicial('proveedor', v_gut, 1972962.10, 'Vuelvo al original');
  v_ok := array_append(v_ok, 'T6');

  -- T7. Aplicar pagos a cuenta: con una factura nueva, los pagos que cancelaron el saldo inicial
  --     NO se aplican (antes sí).
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (v_gut, 'factura', current_date, 'cuenta_corriente', 1000, 0, 1000, c_alicia) RETURNING id INTO v_fac;
  BEGIN
    PERFORM aplicar_pagos_a_cuenta(v_gut, ARRAY[v_fac], NULL);
    RAISE EXCEPTION 'T7: aplicó pagos que cancelan el saldo inicial';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE 'Los pagos a cuenta de este proveedor cancelan su saldo inicial%' THEN RAISE EXCEPTION 'T7a: %', v_msg; END IF;
  END;
  -- Un pago nuevo de 600 sin comprobante: queda libre y se aplica 600 a la factura.
  INSERT INTO pagos_proveedor (proveedor_id, monto, forma_pago, usuario_id) VALUES (v_gut, 600, 'efectivo', c_alicia) RETURNING id INTO v_pago;
  IF (SELECT a_cuenta_libre FROM proveedores_saldo WHERE id = v_gut) <> 600 THEN RAISE EXCEPTION 'T7: libre <> 600'; END IF;
  SELECT (aplicar_pagos_a_cuenta(v_gut, ARRAY[v_fac], NULL))->>'aplicado' INTO v_msg;
  IF v_msg::numeric <> 600 THEN RAISE EXCEPTION 'T7: aplicó %', v_msg; END IF;
  SELECT * INTO r FROM proveedores_saldo WHERE id = v_gut;
  IF r.saldo_actual <> 400 OR r.a_cuenta_libre <> 0 OR r.saldo_inicial_pendiente <> 0 THEN RAISE EXCEPTION 'T7 final: % / % / %', r.saldo_actual, r.a_cuenta_libre, r.saldo_inicial_pendiente; END IF;
  v_ok := array_append(v_ok, 'T7');

  -- T8. Historial: revertir la edición que cargó el saldo (Alicia, 20/10) no pasa; revertir una
  --     edición de teléfono no toca el saldo inicial.
  SELECT id INTO v_aud FROM auditoria
  WHERE registro_id = v_toy AND accion = 'edicion' AND (valores_anteriores->>'saldo_inicial')::numeric = 0
    AND (valores_nuevos->>'saldo_inicial')::numeric = 1120280 LIMIT 1;
  BEGIN
    PERFORM revertir_edicion(v_aud);
    RAISE EXCEPTION 'T8: revirtió la carga del saldo';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE 'Este cambio es del saldo inicial%' THEN RAISE EXCEPTION 'T8a: %', v_msg; END IF;
  END;
  UPDATE proveedores SET telefono = 'T8-viejo' WHERE id = v_toy;
  UPDATE proveedores SET telefono = 'T8-nuevo' WHERE id = v_toy;
  SELECT id INTO v_aud FROM auditoria WHERE registro_id = v_toy AND valores_nuevos->>'telefono' = 'T8-nuevo' ORDER BY created_at DESC LIMIT 1;
  -- Simula una edición vieja: el snapshot anterior tenía saldo_inicial 0.
  UPDATE auditoria SET valores_anteriores = valores_anteriores || '{"saldo_inicial": 0, "saldo_inicial_fecha": null}'::jsonb WHERE id = v_aud;
  PERFORM revertir_edicion(v_aud);
  SELECT * INTO r FROM proveedores WHERE id = v_toy;
  IF r.telefono <> 'T8-viejo' OR r.saldo_inicial <> 1120280 OR r.saldo_inicial_fecha IS NULL THEN RAISE EXCEPTION 'T8: % / % / %', r.telefono, r.saldo_inicial, r.saldo_inicial_fecha; END IF;
  v_ok := array_append(v_ok, 'T8');

  -- T9. Clientes: carga, cobros sin venta cancelan primero el saldo inicial, corrección.
  INSERT INTO clientes (razon_social) VALUES ('ZZ CLIENTE DOCS69') RETURNING id INTO v_cli;
  PERFORM cargar_saldos_iniciales('[]', '[]', jsonb_build_array(jsonb_build_object('cliente_id', v_cli, 'monto', 1000)));
  INSERT INTO pagos_cliente (cliente_id, monto, forma_pago, usuario_id) VALUES (v_cli, 600, 'efectivo', c_alicia);
  SELECT * INTO r FROM clientes_saldo WHERE id = v_cli;
  IF r.saldo_inicial_pendiente <> 400 OR r.a_cuenta_libre <> 0 OR r.a_cuenta <> 600 OR r.saldo_actual <> 400 OR r.saldo_inicial_usuario_nombre <> 'Alicia' THEN
    RAISE EXCEPTION 'T9a: % / % / % / %', r.saldo_inicial_pendiente, r.a_cuenta_libre, r.a_cuenta, r.saldo_actual;
  END IF;
  INSERT INTO pagos_cliente (cliente_id, monto, forma_pago, usuario_id) VALUES (v_cli, 700, 'efectivo', c_alicia);
  SELECT * INTO r FROM clientes_saldo WHERE id = v_cli;
  IF r.saldo_inicial_pendiente <> 0 OR r.a_cuenta_libre <> 300 OR r.saldo_actual <> -300 THEN
    RAISE EXCEPTION 'T9b: % / % / %', r.saldo_inicial_pendiente, r.a_cuenta_libre, r.saldo_actual;
  END IF;
  BEGIN
    PERFORM cargar_saldos_iniciales('[]', '[]', jsonb_build_array(jsonb_build_object('cliente_id', v_cli, 'monto', 50)));
    RAISE EXCEPTION 'T9: cargó dos veces';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE '%ZZ CLIENTE DOCS69 ($ 1.000,00%' THEN RAISE EXCEPTION 'T9c: %', v_msg; END IF;
  END;
  PERFORM corregir_saldo_inicial('cliente', v_cli, 1500, 'Faltaba una venta');
  SELECT * INTO r FROM clientes_saldo WHERE id = v_cli;
  IF r.saldo_inicial_pendiente <> 200 OR r.a_cuenta_libre <> 0 OR r.saldo_actual <> 200 THEN
    RAISE EXCEPTION 'T9d: % / % / %', r.saldo_inicial_pendiente, r.a_cuenta_libre, r.saldo_actual;
  END IF;
  v_ok := array_append(v_ok, 'T9');

  -- T10. Cuentas de dinero: una por cuenta, mensaje con el nombre; montos en cero rechazados.
  PERFORM cargar_saldos_iniciales(jsonb_build_array(jsonb_build_object('cuenta_id', 'c83ad2bd-cbe6-4b69-975c-0853fb886df2', 'monto', 1234.5)), '[]', '[]');
  BEGIN
    PERFORM cargar_saldos_iniciales(jsonb_build_array(jsonb_build_object('cuenta_id', 'c83ad2bd-cbe6-4b69-975c-0853fb886df2', 'monto', 1)), '[]', '[]');
    RAISE EXCEPTION 'T10: dos veces la cuenta';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE '%Galicia ($ 1.234,50)%' THEN RAISE EXCEPTION 'T10a: %', v_msg; END IF;
  END;
  BEGIN
    PERFORM cargar_saldos_iniciales('[]', jsonb_build_array(jsonb_build_object('proveedor_id', v_prov, 'monto', 0)), '[]');
    RAISE EXCEPTION 'T10: monto cero';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg <> 'Cada saldo inicial necesita un monto distinto de cero' THEN RAISE EXCEPTION 'T10b: %', v_msg; END IF;
  END;
  v_ok := array_append(v_ok, 'T10');

  RAISE EXCEPTION 'RESULTADO: OK %', array_to_string(v_ok, ' ');
END $$;
ROLLBACK;
