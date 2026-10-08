# 06 — Estructura de Datos — Virikyna POS

Siguiendo `database-first`: el schema SQL es la fuente de verdad. Nada de UI hasta que estas tablas existan y estén verificadas en Supabase.

Decisiones de schema ya validadas con la clienta:
- 1 Comprobante X = 1 Factura C (relación 1:1, sin agrupar)
- Stock por ubicación: **Local** y **Depósito** (dos ubicaciones reales, no un dato decorativo)
- Una sola terminal para arrancar — `terminal_id` queda preparado pero no se usa en Fase 1
- Auditoría universal vía triggers (no llamadas manuales) — toda acción queda registrada y es visible en Virikyna Gestión. Revertir es siempre una acción nueva, nunca se borra la original.
- **Confirmado:** una venta ya facturada (con CAE) no es reversible desde el sistema — la Nota de Crédito que lo permitiría queda fuera de alcance de Fase 1. El Cierre Z ya validado tampoco se revierte, solo admite nota de corrección.
- **Cuentas (Efectivo, Mercado Pago, Galicia, etc.) con ledger propio** (`cuentas` + `movimientos_cuenta`), mismo principio que el stock: el saldo nunca se pisa, es la suma de movimientos. Permite cargar saldos iniciales y que la dueña anote ingresos/egresos manuales en Caja Gestión, además de lo que impacta solo desde los Cierres Z validados.
- `proveedores.saldo_inicial` y `clientes.saldo_inicial`: deuda con la que arranca cada uno en el sistema, cargada una vez desde Caja Gestión.
- **Mapeo de medios de pago confirmado con la clienta:** Efectivo→Efectivo, Transferencia→Mercado Pago, QR/Débito/Crédito→Galicia (vía tabla `cuenta_forma_pago`). Se edita solo por SQL — sin pantalla de configuración en Fase 1, y limitado a estas 3 cuentas; sumar una cuenta nueva es una tarea de desarrollo, no autoservicio.
- **Pagos de clientes y proveedores ahora impactan en `movimientos_cuenta`** (antes era un gap: el dinero no se reflejaba en ninguna cuenta real). Cheque y echeq de proveedores quedan fuera del ledger de cuentas — no son plata líquida al momento de registrarse.
- **Transferencias entre cuentas** (`transferir_entre_cuentas`) — mover plata de una cuenta a otra, registrado como 2 movimientos vinculados por la misma `referencia_id`.
- **Todo movimiento de cuenta es editable y eliminable**, pero nunca con `UPDATE`/`DELETE` real — siempre vía contra-asiento (`revierte_movimiento_id`), visible en el Historial de Virikyna Gestión igual que cualquier otra acción auditada.

---

## 1. Tipos ENUM

```sql
CREATE TYPE rol_usuario AS ENUM ('admin', 'cajero');

CREATE TYPE estado_producto AS ENUM ('activo', 'inactivo');

CREATE TYPE ubicacion_stock AS ENUM ('local', 'deposito');

CREATE TYPE forma_pago_venta AS ENUM ('efectivo', 'transferencia', 'qr', 'tarjeta_debito', 'tarjeta_credito', 'cuenta_corriente', 'combinado');
-- 'combinado': la venta se pagó con hasta 2 medios distintos — el detalle de cuánto fue a cada
-- uno vive en venta_pagos (ver tabla más abajo), nunca en cuenta corriente (docs/22).

CREATE TYPE estado_comprobante AS ENUM ('sin_facturar', 'facturado', 'anulada');

CREATE TYPE tipo_comprobante_compra AS ENUM ('factura', 'remito', 'cupon', 'presupuesto', 'nota_credito', 'nota_debito');

CREATE TYPE letra_comprobante_compra AS ENUM ('A', 'B', 'R', 'X');

CREATE TYPE forma_pago_compra AS ENUM ('contado', 'cuenta_corriente');

CREATE TYPE forma_pago_egreso AS ENUM ('efectivo', 'transferencia', 'cheque', 'echeq');

CREATE TYPE tipo_cierre AS ENUM ('x', 'z');

CREATE TYPE estado_cierre_z AS ENUM ('pendiente_validacion', 'validado');

CREATE TYPE origen_egreso AS ENUM ('turno', 'general');

CREATE TYPE tipo_movimiento_stock AS ENUM ('venta', 'compra', 'ajuste');  -- + 'inicial' (docs/34, sección 24)

CREATE TYPE tipo_accion_auditoria AS ENUM ('alta', 'edicion', 'eliminacion', 'anulacion', 'reversion', 'nota_correccion');

CREATE TYPE tipo_movimiento_cuenta AS ENUM ('saldo_inicial', 'venta', 'pago_cliente', 'pago_proveedor', 'egreso', 'ingreso_manual', 'cierre_z', 'transferencia_interna');

CREATE TYPE categoria_egreso AS ENUM ('pago_proveedor', 'sueldo', 'servicio', 'otro');

-- Agregado en la integración real con ARCA: obligatorio para Factura C desde RG 5616
-- (ver FEParamGetCondicionIvaReceptor de WSFEv1). Cubre los casos reales de Virikyna —
-- nada de exterior ni IVA Liberado Ley 19.640.
CREATE TYPE condicion_iva_cliente AS ENUM (
  'consumidor_final',
  'responsable_inscripto',
  'monotributista',
  'exento',
  'no_categorizado'
);
```

---

## 2. Tablas sin FK

```sql
-- Perfiles: espejo de auth.users, con rol de negocio
CREATE TABLE perfiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id),
  nombre TEXT NOT NULL,
  rol rol_usuario NOT NULL,
  activo BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE proveedores (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  razon_social TEXT NOT NULL,
  cuit TEXT,
  direccion TEXT,
  telefono TEXT,
  mail TEXT,
  contacto TEXT,
  margen_1_default NUMERIC(6,2) NOT NULL DEFAULT 0,  -- % markup 1 por defecto para productos nuevos de este proveedor
  margen_2_default NUMERIC(6,2) NOT NULL DEFAULT 0,  -- % markup 2 por defecto
  saldo_inicial NUMERIC(12,2) NOT NULL DEFAULT 0,  -- deuda con la que arranca en el sistema (carga única desde Caja Gestión)
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE clientes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  razon_social TEXT,
  nombre_fantasia TEXT,
  cuit TEXT,
  domicilio TEXT,
  mail TEXT,
  celular TEXT,
  activo BOOLEAN NOT NULL DEFAULT true,
  saldo_inicial NUMERIC(12,2) NOT NULL DEFAULT 0,  -- deuda con la que arranca en el sistema (carga única desde Caja Gestión)
  condicion_iva condicion_iva_cliente NOT NULL DEFAULT 'consumidor_final',  -- para CondicionIVAReceptorId de ARCA (RG 5616)
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- Nota: ningún dato es obligatorio salvo un nombre identificatorio (razon_social o nombre_fantasia) — CHECK abajo.
ALTER TABLE clientes ADD CONSTRAINT chk_cliente_tiene_nombre
  CHECK (razon_social IS NOT NULL OR nombre_fantasia IS NOT NULL);
```

---

## 3. Tablas con FK (en orden de dependencia)

```sql
-- Auditoría universal: poblada por triggers, no por las apps.
-- Es la fuente de "Historial y Auditoría" en Virikyna Gestión.
CREATE TABLE auditoria (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tabla_afectada TEXT NOT NULL,
  registro_id UUID NOT NULL,
  accion tipo_accion_auditoria NOT NULL,
  valores_anteriores JSONB,
  valores_nuevos JSONB,
  usuario_id UUID REFERENCES perfiles(id),  -- nullable a propósito: NULL = acción hecha directo por SQL (mantenimiento), no por la app
  revierte_auditoria_id UUID REFERENCES auditoria(id),  -- si esta fila es una reversión, apunta a la fila que revierte
  nota TEXT,  -- usado por 'nota_correccion' (ej. sobre un Cierre Z)
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_auditoria_tabla_registro ON auditoria(tabla_afectada, registro_id);
CREATE INDEX idx_auditoria_usuario ON auditoria(usuario_id);
CREATE INDEX idx_auditoria_created_at ON auditoria(created_at DESC);

-- Cuentas: los "formatos" de plata que maneja el negocio (Efectivo, Mercado Pago, Galicia, etc.)
-- Exclusivo Caja Gestión — el cajero nunca opera esto directo.
CREATE TABLE cuentas (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre TEXT NOT NULL UNIQUE,  -- 'Efectivo', 'Mercado Pago', 'Galicia'
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Mapeo entre forma de pago de venta y la cuenta real que la recibe.
-- Una cuenta puede recibir varias formas de pago (ej. Galicia recibe QR y tarjeta),
-- pero cada forma de pago pertenece a una sola cuenta — por eso forma_pago es PK acá, no cuenta_id.
CREATE TABLE IF NOT EXISTS cuenta_forma_pago (
  forma_pago forma_pago_venta PRIMARY KEY,
  cuenta_id UUID NOT NULL REFERENCES cuentas(id)
);
-- Seed real de Virikyna (ejecutar una vez, después de crear las 3 cuentas):
-- INSERT INTO cuenta_forma_pago (forma_pago, cuenta_id) VALUES
--   ('efectivo',        (SELECT id FROM cuentas WHERE nombre = 'Efectivo')),
--   ('transferencia',   (SELECT id FROM cuentas WHERE nombre = 'Mercado Pago')),
--   ('qr',              (SELECT id FROM cuentas WHERE nombre = 'Galicia')),
--   ('tarjeta_debito',  (SELECT id FROM cuentas WHERE nombre = 'Galicia')),
--   ('tarjeta_credito', (SELECT id FROM cuentas WHERE nombre = 'Galicia'));

-- Ledger de cada cuenta — el saldo NUNCA se pisa, siempre es la suma de estos movimientos.
-- Mismo principio que movimientos_stock: deltas, no valores absolutos.
CREATE TABLE movimientos_cuenta (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cuenta_id UUID NOT NULL REFERENCES cuentas(id),
  tipo tipo_movimiento_cuenta NOT NULL,
  monto NUMERIC(12,2) NOT NULL,  -- positivo = ingreso, negativo = egreso
  descripcion TEXT,  -- obligatorio si tipo IN ('ingreso_manual','egreso','transferencia_interna'), validado en el RPC
  referencia_id UUID,  -- venta_id, cierre_caja_id, pago_proveedor_id, o un id compartido para vincular una transferencia (2 filas)
  revierte_movimiento_id UUID REFERENCES movimientos_cuenta(id),  -- si esta fila corrige/anula a otra, apunta a esa fila original
  usuario_id UUID NOT NULL REFERENCES perfiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_movimientos_cuenta_cuenta ON movimientos_cuenta(cuenta_id);
-- Saldo actual de una cuenta: SELECT COALESCE(SUM(monto), 0) FROM movimientos_cuenta WHERE cuenta_id = ?

CREATE TABLE productos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre TEXT NOT NULL,
  descripcion TEXT,
  codigo_barras TEXT UNIQUE,
  codigo_interno TEXT UNIQUE,  -- generado por el sistema si no hay codigo_barras
  proveedor_id UUID REFERENCES proveedores(id),
  marca TEXT,
  costo NUMERIC(12,2) NOT NULL DEFAULT 0,  -- ⚠ docs/34 (sección 24): nullable, sin default, + precio_manual
  margen_1 NUMERIC(6,2) NOT NULL DEFAULT 0,
  margen_2 NUMERIC(6,2) NOT NULL DEFAULT 0,
  iva_porcentaje NUMERIC(5,2) NOT NULL DEFAULT 21,
  -- precio de venta derivado, siempre consistente con costo/margen/iva.
  -- ⚠ No es la versión vigente: docs/29 (sección 20) agregó precio_calculado (fórmula exacta a 2
  -- decimales) y docs/30 (sección 21) redondea precio_venta con redondear_precio_venta (escalonado).
  precio_venta NUMERIC(12,2) GENERATED ALWAYS AS (
    ROUND(costo * (1 + margen_1/100.0) * (1 + margen_2/100.0) * (1 + iva_porcentaje/100.0), 2)
  ) STORED,
  stock_minimo NUMERIC(10,2) NOT NULL DEFAULT 0,
  estado estado_producto NOT NULL DEFAULT 'activo',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CHECK (codigo_barras IS NOT NULL OR codigo_interno IS NOT NULL); -- ver nota abajo

-- Stock por ubicación — 2 filas por producto (local / deposito)
CREATE TABLE stock_ubicaciones (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  producto_id UUID NOT NULL REFERENCES productos(id) ON DELETE CASCADE,
  ubicacion ubicacion_stock NOT NULL,
  cantidad NUMERIC(10,2) NOT NULL DEFAULT 0,
  UNIQUE(producto_id, ubicacion)
);

-- Historial de todo movimiento de stock — trazabilidad total
CREATE TABLE movimientos_stock (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  producto_id UUID NOT NULL REFERENCES productos(id),
  ubicacion ubicacion_stock NOT NULL,
  tipo tipo_movimiento_stock NOT NULL,
  cantidad NUMERIC(10,2) NOT NULL,  -- positivo = ingreso, negativo = egreso
  motivo TEXT,  -- obligatorio solo si tipo = 'ajuste', validado en el RPC
  referencia_id UUID,  -- venta_id o factura_compra_id, según tipo
  usuario_id UUID NOT NULL REFERENCES perfiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Ventas / Comprobante X
CREATE TABLE ventas (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  numero BIGINT GENERATED ALWAYS AS IDENTITY,
  cliente_id UUID REFERENCES clientes(id),  -- null = consumidor final
  forma_pago forma_pago_venta NOT NULL,
  subtotal NUMERIC(12,2) NOT NULL,
  descuento_porcentaje NUMERIC(5,2) NOT NULL DEFAULT 0,
  recargo_porcentaje NUMERIC(5,2) NOT NULL DEFAULT 0,
  total NUMERIC(12,2) NOT NULL,  -- = precio_cobrado (docs/23) — todo lo que ya lee "total" (comprobante, Factura C/ARCA, saldo de cta. cte.) sigue reflejando lo realmente cobrado sin tocarse
  precio_oficial NUMERIC(12,2) NOT NULL,  -- docs/23: precio calculado por el sistema (subtotal con descuento/recargo), antes del redondeo manual del cajero
  precio_cobrado NUMERIC(12,2) NOT NULL,  -- docs/23: precio confirmado/editado por el cajero al cerrar la venta — puede ser igual a precio_oficial
  estado estado_comprobante NOT NULL DEFAULT 'sin_facturar',
  nota TEXT,
  terminal_id TEXT NOT NULL DEFAULT 'POS001',  -- preparado para multi-caja futura, sin uso real en Fase 1
  usuario_id UUID NOT NULL REFERENCES perfiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- Corregido en QA: una venta a cuenta corriente siempre necesita un cliente asignado —
-- protegido a nivel schema, no solo en el RPC, para que ni un INSERT directo lo salte.
ALTER TABLE ventas ADD CONSTRAINT chk_venta_cta_cte_requiere_cliente
  CHECK (NOT (forma_pago = 'cuenta_corriente' AND cliente_id IS NULL));
ALTER TABLE ventas ADD CONSTRAINT chk_ventas_precio_cobrado_positivo CHECK (precio_cobrado > 0);

CREATE TABLE venta_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  venta_id UUID NOT NULL REFERENCES ventas(id) ON DELETE CASCADE,
  producto_id UUID NOT NULL REFERENCES productos(id),
  cantidad NUMERIC(10,2) NOT NULL,
  precio_unitario NUMERIC(12,2) NOT NULL,  -- snapshot del precio al momento de vender
  descuento_porcentaje NUMERIC(5,2) NOT NULL DEFAULT 0,
  importe NUMERIC(12,2) NOT NULL
);

-- Detalle de pagos combinados (docs/22) — 1 fila = 1 medio de pago de la venta. Se puebla para
-- TODA venta que no sea cuenta corriente: 1 fila si es pago simple (el total completo), 2 si es
-- combinado. Cuenta corriente queda afuera — sigue sin combinarse con otro medio.
CREATE TABLE venta_pagos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  venta_id UUID NOT NULL REFERENCES ventas(id) ON DELETE CASCADE,
  forma_pago forma_pago_venta NOT NULL,
  monto NUMERIC(12,2) NOT NULL,
  usuario_id UUID NOT NULL REFERENCES perfiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE venta_pagos ADD CONSTRAINT chk_venta_pagos_no_cta_cte
  CHECK (forma_pago NOT IN ('cuenta_corriente', 'combinado'));
ALTER TABLE venta_pagos ADD CONSTRAINT chk_venta_pagos_monto_positivo CHECK (monto > 0);

-- Factura C — 1:1 con la venta
CREATE TABLE facturas_c (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  venta_id UUID NOT NULL UNIQUE REFERENCES ventas(id),
  cae TEXT,
  numero_factura TEXT,
  punto_venta TEXT,
  fecha_emision TIMESTAMPTZ,
  pdf_url TEXT,
  enviado_a TEXT,  -- mail o celular al que se envió, si se envió
  usuario_id UUID NOT NULL REFERENCES perfiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Caché del TA (ticket de acceso) de WSAA para la Edge Function arca-emitir-factura —
-- ARCA rechaza pedir un TA nuevo mientras exista uno vigente para el mismo servicio+CUIT
-- (dura ~12hs), y una Edge Function no garantiza memoria compartida entre invocaciones.
-- Exclusivo del backend: solo lee/escribe con service_role, RLS sin policies.
-- "ambiente" separa homologación de producción: son TAs de WSAA completamente distintos
-- (servidores distintos), no pueden compartir la misma fila de caché.
CREATE TABLE IF NOT EXISTS arca_wsaa_tokens (
  servicio TEXT NOT NULL,
  cuit TEXT NOT NULL,
  ambiente TEXT NOT NULL DEFAULT 'homologacion',
  token TEXT NOT NULL,
  sign TEXT NOT NULL,
  expiration_time TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (servicio, cuit, ambiente)
);
ALTER TABLE arca_wsaa_tokens ENABLE ROW LEVEL SECURITY;

-- Facturas de compra (proveedores)
CREATE TABLE facturas_compra (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  proveedor_id UUID NOT NULL REFERENCES proveedores(id),
  tipo_comprobante tipo_comprobante_compra NOT NULL,
  letra letra_comprobante_compra,
  punto_venta TEXT,
  numero_comprobante TEXT,
  fecha_comprobante DATE NOT NULL,
  fecha_fiscal DATE,
  forma_pago forma_pago_compra NOT NULL,
  total_sin_iva NUMERIC(12,2) NOT NULL,
  iva NUMERIC(12,2) NOT NULL,
  total NUMERIC(12,2) NOT NULL,
  usuario_id UUID NOT NULL REFERENCES perfiles(id),
  anulada BOOLEAN NOT NULL DEFAULT false,  -- exclusivo Gestión: anular_factura_compra revierte stock y marca esto
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  copiada_de_id UUID REFERENCES facturas_compra(id)  -- docs/33 (sección 23): factura de la que se copió esta
);

CREATE TABLE facturas_compra_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factura_compra_id UUID NOT NULL REFERENCES facturas_compra(id) ON DELETE CASCADE,
  producto_id UUID REFERENCES productos(id),  -- null = ítem libre (ej. "juguetes varios", ajustes)
  descripcion TEXT NOT NULL,
  cantidad NUMERIC(10,2) NOT NULL,
  precio_unitario_sin_iva NUMERIC(12,2) NOT NULL,
  descuento_porcentaje NUMERIC(5,2) NOT NULL DEFAULT 0,
  precio_total_sin_iva NUMERIC(12,2) NOT NULL,
  ubicacion ubicacion_stock NOT NULL DEFAULT 'local'
);

-- Pagos a proveedor (cuenta corriente)
-- ⚠ docs/31 (sección 22): + fecha, + nota; factura_compra_id DEPRECATED — la imputación vive en
-- pagos_proveedor_aplicaciones (un pago puede cancelar varias facturas y usar notas de crédito).
CREATE TABLE pagos_proveedor (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  proveedor_id UUID NOT NULL REFERENCES proveedores(id),
  factura_compra_id UUID REFERENCES facturas_compra(id),  -- null = pago a cuenta general
  monto NUMERIC(12,2) NOT NULL,
  forma_pago forma_pago_egreso NOT NULL,
  usuario_id UUID NOT NULL REFERENCES perfiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Pagos/cobros de clientes con cuenta corriente
CREATE TABLE pagos_cliente (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id UUID NOT NULL REFERENCES clientes(id),
  venta_id UUID REFERENCES ventas(id),  -- a qué venta se aplica (el cajero elige); null = a cuenta general
  monto NUMERIC(12,2) NOT NULL,
  forma_pago forma_pago_venta NOT NULL,
  usuario_id UUID NOT NULL REFERENCES perfiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE pagos_cliente ADD CONSTRAINT chk_pago_cliente_forma_pago CHECK (forma_pago NOT IN ('cuenta_corriente', 'combinado'));
-- No tiene sentido "pagar la cuenta corriente... con cuenta corriente" — siempre es plata real entrando.

-- Cierres de caja (X y Z)
CREATE TABLE cierres_caja (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo tipo_cierre NOT NULL,
  turno_fecha DATE NOT NULL,
  total_efectivo NUMERIC(12,2) NOT NULL DEFAULT 0,
  total_transferencia NUMERIC(12,2) NOT NULL DEFAULT 0,
  total_qr NUMERIC(12,2) NOT NULL DEFAULT 0,
  total_tarjeta NUMERIC(12,2) NOT NULL DEFAULT 0,
  total_cuenta_corriente NUMERIC(12,2) NOT NULL DEFAULT 0,
  total_egresos NUMERIC(12,2) NOT NULL DEFAULT 0,
  total_retiros NUMERIC(12,2) NOT NULL DEFAULT 0,  -- docs/17: retiros de efectivo del día
  efectivo_esperado NUMERIC(12,2) NOT NULL DEFAULT 0,
  efectivo_contado NUMERIC(12,2),
  diferencia NUMERIC(12,2),
  usuario_id UUID NOT NULL REFERENCES perfiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- Encontrada en QA sin documentar: garantiza un solo Cierre Z por día (Cierre X sí se puede repetir).
CREATE UNIQUE INDEX ux_cierres_caja_z_unico_por_dia ON cierres_caja (turno_fecha) WHERE tipo = 'z';

-- Egresos: de turno (cajero) o generales (Caja Gestión, solo admin)
CREATE TABLE egresos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cierre_caja_id UUID REFERENCES cierres_caja(id),  -- null si es un egreso general no atado a un cierre puntual
  origen origen_egreso NOT NULL,
  categoria categoria_egreso NOT NULL,  -- pago_proveedor | sueldo | servicio | otro | agua | descartables | super (agua/descartables/super: docs/13, categorías de turno en Local)
  monto NUMERIC(12,2) NOT NULL,
  descripcion TEXT,
  forma_pago forma_pago_egreso NOT NULL,
  usuario_id UUID NOT NULL REFERENCES perfiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**Nota sobre `productos`:** el `CHECK` de código de barras/interno se agrega como `ALTER TABLE` separado si Postgres exige que la columna `precio_venta` (generada) ya exista antes de agregar otro constraint — ejecutar y verificar en Supabase SQL Editor antes de continuar.

---

## 4. Índices

```sql
CREATE INDEX idx_productos_proveedor ON productos(proveedor_id);
CREATE INDEX idx_productos_estado ON productos(estado);
CREATE INDEX idx_ventas_estado ON ventas(estado);
CREATE INDEX idx_ventas_created_at ON ventas(created_at);
CREATE INDEX idx_ventas_cliente ON ventas(cliente_id);
CREATE INDEX idx_venta_pagos_venta ON venta_pagos(venta_id);
CREATE INDEX idx_movimientos_stock_producto ON movimientos_stock(producto_id);
CREATE INDEX idx_facturas_compra_proveedor ON facturas_compra(proveedor_id);
CREATE INDEX idx_cierres_caja_fecha ON cierres_caja(turno_fecha, tipo);
```

---

## 5. RLS — patrón de roles

```sql
-- perfiles: regla de oro, sin recursión
ALTER TABLE perfiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "perfil_propio" ON perfiles FOR SELECT USING (auth.uid() = id);
-- ADVERTENCIA (encontrado en QA): no agregar una policy tipo "activo = true" para listar usuarios —
-- eso expone rol y estado de todos a cualquier logueado. Si una pantalla necesita listar nombres
-- de usuarios activos (ej. "Cambiar de usuario"), usar la vista perfiles_publico de abajo, nunca
-- una policy amplia sobre la tabla perfiles.
CREATE OR REPLACE VIEW perfiles_publico AS
SELECT id, nombre FROM perfiles WHERE activo = true;
GRANT SELECT ON perfiles_publico TO authenticated;

-- Tablas operativas: admin y cajero acceden por igual salvo excepciones puntuales
ALTER TABLE ventas ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ventas_todos" ON ventas FOR ALL USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
);

ALTER TABLE venta_pagos ENABLE ROW LEVEL SECURITY;
CREATE POLICY "venta_pagos_todos" ON venta_pagos FOR ALL USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
);

-- Ejemplo de excepción: solo admin ajusta stock (se valida en el RPC, no solo en RLS)
ALTER TABLE movimientos_stock ENABLE ROW LEVEL SECURITY;
CREATE POLICY "movimientos_stock_select" ON movimientos_stock FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
);

-- Configuración de usuarios: exclusivo admin
ALTER TABLE perfiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admin_gestiona_usuarios" ON perfiles FOR ALL USING (
  EXISTS (SELECT 1 FROM perfiles p WHERE p.id = auth.uid() AND p.rol = 'admin')
) WITH CHECK (
  EXISTS (SELECT 1 FROM perfiles p WHERE p.id = auth.uid() AND p.rol = 'admin')
);
-- Nota: esta policy consulta la MISMA tabla perfiles → riesgo de recursión.
-- Usar cliente service_role desde una función de servidor para gestión de usuarios,
-- no RLS directo sobre perfiles (regla de oro del skill database-first).

-- Caja Gestión / validar Cierre Z: exclusivo admin
ALTER TABLE cierres_caja ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cierres_ver_todos" ON cierres_caja FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
);
CREATE POLICY "cierres_validar_solo_admin" ON cierres_caja FOR UPDATE USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
);

-- Auditoría: exclusiva admin, y de solo lectura para todos (append-only real)
ALTER TABLE auditoria ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auditoria_select_solo_admin" ON auditoria FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
);
-- Sin policy de INSERT para el cliente: solo el trigger (SECURITY DEFINER) escribe acá.
-- Sin policy de UPDATE ni DELETE para nadie, ni siquiera admin — la auditoría no se edita ni se borra jamás.

-- Cuentas y sus movimientos: exclusivo admin (Caja Gestión), el cajero no opera esto directo
ALTER TABLE cuentas ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cuentas_solo_admin" ON cuentas FOR ALL USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
);
ALTER TABLE cuenta_forma_pago ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cuenta_forma_pago_solo_admin" ON cuenta_forma_pago FOR ALL USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
);
ALTER TABLE movimientos_cuenta ENABLE ROW LEVEL SECURITY;
CREATE POLICY "movimientos_cuenta_select_admin" ON movimientos_cuenta FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
);
-- Sin policy de INSERT directo: todo movimiento de cuenta pasa por un RPC (cargar_saldos_iniciales,
-- registrar_movimiento_caja_general, transferir_entre_cuentas, editar/eliminar_movimiento_cuenta, o validar_cierre_z),
-- nunca por un INSERT libre del cliente.
```

Repetir el patrón `_todos` (ambos roles) en: `proveedores`, `productos`, `stock_ubicaciones`, `clientes`, `facturas_compra`, `facturas_compra_items`, `pagos_proveedor`, `pagos_cliente`, `facturas_c`, `egresos`, `notas_internas` (sección 14).

---

## 6. Auditoría automática — triggers, no llamadas manuales

**Principio:** la auditoría nunca depende de que una función de negocio "se acuerde" de loggear. Se implementa con un trigger genérico que se cuelga de cada tabla relevante — así es imposible que un cambio quede sin registrar.

```sql
CREATE OR REPLACE FUNCTION fn_auditoria_generica() RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_nuevos, usuario_id)
    VALUES (TG_TABLE_NAME, NEW.id, 'alta', to_jsonb(NEW), auth.uid());
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, valores_nuevos, usuario_id)
    VALUES (TG_TABLE_NAME, NEW.id, 'edicion', to_jsonb(OLD), to_jsonb(NEW), auth.uid());
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, usuario_id)
    VALUES (TG_TABLE_NAME, OLD.id, 'eliminacion', to_jsonb(OLD), auth.uid());
    RETURN OLD;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Colgar el trigger de cada tabla que debe auditarse:
CREATE TRIGGER trg_auditoria_productos AFTER INSERT OR UPDATE OR DELETE ON productos
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();
CREATE TRIGGER trg_auditoria_proveedores AFTER INSERT OR UPDATE OR DELETE ON proveedores
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();
CREATE TRIGGER trg_auditoria_clientes AFTER INSERT OR UPDATE OR DELETE ON clientes
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();
CREATE TRIGGER trg_auditoria_ventas AFTER INSERT OR UPDATE OR DELETE ON ventas
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();
CREATE TRIGGER trg_auditoria_stock_ubicaciones AFTER UPDATE ON stock_ubicaciones
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();
CREATE TRIGGER trg_auditoria_egresos AFTER INSERT OR UPDATE OR DELETE ON egresos
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();
CREATE TRIGGER trg_auditoria_pagos_proveedor AFTER INSERT OR UPDATE OR DELETE ON pagos_proveedor
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();
CREATE TRIGGER trg_auditoria_pagos_cliente AFTER INSERT OR UPDATE OR DELETE ON pagos_cliente
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();
-- Gap encontrado en QA: facturas_compra nunca tuvo su trigger, a pesar de estar en la lista de tablas "a repetir"
CREATE TRIGGER trg_auditoria_facturas_compra AFTER INSERT OR UPDATE ON facturas_compra
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();
CREATE TRIGGER trg_auditoria_movimientos_cuenta AFTER INSERT ON movimientos_cuenta
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();
-- Repetir en cada tabla operativa que deba quedar trazada.
-- movimientos_stock NO necesita trigger propio: es en sí misma un log, ya inmutable.
```

**Nota:** `auth.uid()` dentro de un trigger solo funciona si la conexión mantiene el contexto de sesión de Supabase (rol `authenticated`, no `service_role` de un job de fondo). Si alguna escritura se hace desde un proceso de servidor sin sesión de usuario, pasar el `usuario_id` explícito en vez de depender de `auth.uid()`.

## 7. RPCs de reversión — una por tipo de entidad, nunca un "undo" genérico

Cada `revertir_*` hace su propia validación de negocio, escribe la reversión (que a su vez el trigger de auditoría registra como una fila más), y nunca borra la fila de auditoría original.

```sql
-- Revertir un cambio de campo simple (precio, margen, dato de ficha)
CREATE OR REPLACE FUNCTION revertir_edicion(p_auditoria_id UUID) RETURNS VOID AS $$
DECLARE
  v_auditoria auditoria%ROWTYPE;
BEGIN
  SELECT * INTO v_auditoria FROM auditoria WHERE id = p_auditoria_id AND accion = 'edicion';
  IF NOT FOUND THEN RAISE EXCEPTION 'Acción no encontrada o no reversible'; END IF;
  -- Validar rol admin del usuario autenticado antes de continuar (queda fuera de este pseudo-código)
  -- Aplicar valores_anteriores sobre la tabla_afectada, vía EXECUTE dinámico según tabla_afectada
  -- INSERT INTO auditoria (accion='reversion', revierte_auditoria_id=p_auditoria_id, ...)
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Anular una venta NO facturada: repone stock, marca la venta como anulada
CREATE OR REPLACE FUNCTION anular_venta(p_venta_id UUID, p_motivo TEXT) RETURNS VOID AS $$
BEGIN
  -- Validar que la venta NO tenga factura_c asociada (si la tiene, RAISE EXCEPTION — no es reversible acá)
  -- Por cada venta_item: INSERT INTO movimientos_stock (tipo='ajuste', cantidad positiva = reposición)
  -- UPDATE ventas SET estado = 'anulada' (valor ya agregado al enum estado_comprobante)
  -- INSERT INTO auditoria (accion='anulacion', ...)
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Revertir un ajuste de stock, egreso o pago: contra-asiento, nunca borra el original
CREATE OR REPLACE FUNCTION revertir_movimiento(p_auditoria_id UUID) RETURNS VOID AS $$
BEGIN
  -- Genera el movimiento inverso correspondiente según tabla_afectada
  -- INSERT INTO auditoria (accion='reversion', revierte_auditoria_id=p_auditoria_id, ...)
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Nota de corrección sobre un Cierre Z ya validado: no reabre el cierre, solo lo anota
CREATE OR REPLACE FUNCTION agregar_nota_correccion(p_cierre_id UUID, p_nota TEXT) RETURNS VOID AS $$
BEGIN
  INSERT INTO auditoria (tabla_afectada, registro_id, accion, nota, usuario_id)
  VALUES ('cierres_caja', p_cierre_id, 'nota_correccion', p_nota, auth.uid());
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Venta ya facturada (con CAE): sin RPC de reversión, por diseño y por decisión confirmada con la clienta.** No existe `revertir_venta_facturada` — no es técnicamente correcto revertir un comprobante fiscal ya emitido ante ARCA, y la Nota de Crédito que lo permitiría queda fuera de alcance de Fase 1.

## 8. RPCs (operaciones atómicas)

Usar función `SECURITY DEFINER` cuando una acción toca más de una tabla — nunca dejarlo resuelto solo del lado del cliente. Código completo, listo para ejecutar (no pseudo-código):

```sql
-- ============================================================
-- Ajuste de schema necesario antes de estas funciones:
-- ============================================================
ALTER TYPE estado_comprobante ADD VALUE IF NOT EXISTS 'anulada';
-- (correr esta línea sola, esperar a que termine, recién después seguir con el resto —
-- Postgres no permite usar un valor de enum nuevo en la misma transacción que lo crea)

-- ============================================================
-- 1. confirmar_venta
-- Descuento y recargo (docs/20) son porcentajes multiplicativos sobre el mismo subtotal.
-- p_pagos (docs/22) es opcional: sin él, pago simple por p_forma_pago de siempre. Con él (hasta
-- 2 medios, sin cuenta corriente, suma exacta al precio oficial), la venta queda
-- forma_pago='combinado' y el detalle por medio se guarda en venta_pagos.
-- p_precio_cobrado (docs/23) es opcional: sin él (o NULL), precio_cobrado = precio_oficial. Con
-- él, es el precio final que el cajero confirmó en la ventanita de confirmación de venta — puede
-- ser distinto al oficial (redondeo manual, sin restricción de monto). ventas.total pasa a
-- significar precio_cobrado de acá en más.
-- ============================================================
CREATE OR REPLACE FUNCTION confirmar_venta(
  p_cliente_id UUID,
  p_forma_pago forma_pago_venta,
  p_items JSONB,  -- [{"producto_id":"...", "cantidad":1, "precio_unitario":12500, "descuento_porcentaje":0}]
  p_descuento_porcentaje NUMERIC DEFAULT 0,
  p_nota TEXT DEFAULT NULL,
  p_recargo_porcentaje NUMERIC DEFAULT 0,
  p_pagos JSONB DEFAULT NULL,  -- [{"forma_pago":"efectivo","monto":500},{"forma_pago":"tarjeta_credito","monto":1000}]
  p_precio_cobrado NUMERIC DEFAULT NULL  -- precio final editado por el cajero; NULL = igual al oficial
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_venta_id UUID;
  v_item JSONB;
  v_pago JSONB;
  v_subtotal NUMERIC := 0;
  v_precio_oficial NUMERIC;
  v_precio_cobrado NUMERIC;
  v_ratio NUMERIC;
  v_importe NUMERIC;
  v_forma_pago_final forma_pago_venta;
  v_suma_pagos NUMERIC;
  v_suma_ajustada NUMERIC := 0;
  v_monto_ajustado NUMERIC;
  v_idx INT := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  SELECT COALESCE(SUM((i->>'cantidad')::NUMERIC * (i->>'precio_unitario')::NUMERIC
           * (1 - COALESCE((i->>'descuento_porcentaje')::NUMERIC,0)/100.0)), 0)
  INTO v_subtotal
  FROM jsonb_array_elements(p_items) AS i;

  v_precio_oficial := ROUND(v_subtotal * (1 - COALESCE(p_descuento_porcentaje,0)/100.0)
                    * (1 + COALESCE(p_recargo_porcentaje,0)/100.0), 2);

  IF p_pagos IS NOT NULL AND jsonb_array_length(p_pagos) > 0 THEN
    IF jsonb_array_length(p_pagos) > 2 THEN
      RAISE EXCEPTION 'Un pago combinado admite hasta 2 medios de pago';
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_pagos) AS p
      WHERE (p->>'forma_pago') IN ('cuenta_corriente', 'combinado')
    ) THEN
      RAISE EXCEPTION 'La cuenta corriente no puede combinarse con otro medio de pago';
    END IF;
    -- La validación de la suma es contra el precio OFICIAL: es el monto con el que se armó el
    -- reparto en PagoCombinadoModal, antes de que el cajero edite el precio final a cobrar.
    SELECT COALESCE(SUM((p->>'monto')::NUMERIC), 0) INTO v_suma_pagos FROM jsonb_array_elements(p_pagos) AS p;
    IF ROUND(v_suma_pagos, 2) <> v_precio_oficial THEN
      RAISE EXCEPTION 'La suma de los pagos (%) no coincide con el total de la venta (%)', v_suma_pagos, v_precio_oficial;
    END IF;
    v_forma_pago_final := CASE WHEN jsonb_array_length(p_pagos) = 1
      THEN (p_pagos->0->>'forma_pago')::forma_pago_venta
      ELSE 'combinado'::forma_pago_venta END;
  ELSE
    v_forma_pago_final := p_forma_pago;
  END IF;

  -- Corregido en QA: mensaje claro antes de chocar con el CHECK del schema
  IF v_forma_pago_final = 'cuenta_corriente' AND p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'Una venta a cuenta corriente necesita un cliente asignado';
  END IF;

  v_precio_cobrado := COALESCE(p_precio_cobrado, v_precio_oficial);
  IF v_precio_cobrado <= 0 THEN
    RAISE EXCEPTION 'El precio final a cobrar debe ser mayor a 0';
  END IF;

  INSERT INTO ventas (cliente_id, forma_pago, subtotal, descuento_porcentaje, recargo_porcentaje, total,
         precio_oficial, precio_cobrado, nota, usuario_id)
  VALUES (p_cliente_id, v_forma_pago_final, v_subtotal, COALESCE(p_descuento_porcentaje,0),
          COALESCE(p_recargo_porcentaje,0), v_precio_cobrado, v_precio_oficial, v_precio_cobrado, p_nota, auth.uid())
  RETURNING id INTO v_venta_id;

  IF v_forma_pago_final <> 'cuenta_corriente' THEN
    IF p_pagos IS NOT NULL AND jsonb_array_length(p_pagos) > 0 THEN
      -- Reescala cada parte al precio cobrado, manteniendo la proporción del reparto original —
      -- la última parte absorbe el centavo de redondeo para que la suma dé exacta.
      v_ratio := CASE WHEN v_precio_oficial = 0 THEN 1 ELSE v_precio_cobrado / v_precio_oficial END;
      FOR v_pago IN SELECT * FROM jsonb_array_elements(p_pagos)
      LOOP
        v_idx := v_idx + 1;
        IF v_idx = jsonb_array_length(p_pagos) THEN
          v_monto_ajustado := v_precio_cobrado - v_suma_ajustada;
        ELSE
          v_monto_ajustado := ROUND((v_pago->>'monto')::NUMERIC * v_ratio, 2);
          v_suma_ajustada := v_suma_ajustada + v_monto_ajustado;
        END IF;
        INSERT INTO venta_pagos (venta_id, forma_pago, monto, usuario_id)
        VALUES (v_venta_id, (v_pago->>'forma_pago')::forma_pago_venta, v_monto_ajustado, auth.uid());
      END LOOP;
    ELSE
      INSERT INTO venta_pagos (venta_id, forma_pago, monto, usuario_id)
      VALUES (v_venta_id, v_forma_pago_final, v_precio_cobrado, auth.uid());
    END IF;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_importe := ROUND((v_item->>'cantidad')::NUMERIC * (v_item->>'precio_unitario')::NUMERIC
                 * (1 - COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0)/100.0), 2);

    INSERT INTO venta_items (venta_id, producto_id, cantidad, precio_unitario, descuento_porcentaje, importe)
    VALUES (v_venta_id, (v_item->>'producto_id')::UUID, (v_item->>'cantidad')::NUMERIC,
            (v_item->>'precio_unitario')::NUMERIC, COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0), v_importe);

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, referencia_id, usuario_id)
    VALUES ((v_item->>'producto_id')::UUID, 'local', 'venta', -1 * (v_item->>'cantidad')::NUMERIC, v_venta_id, auth.uid());

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES ((v_item->>'producto_id')::UUID, 'local', -1 * (v_item->>'cantidad')::NUMERIC)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad - (v_item->>'cantidad')::NUMERIC;
  END LOOP;

  RETURN v_venta_id;
END;
$$;

-- ============================================================
-- 2. cargar_factura_compra
-- ⚠ No es la versión vigente: ver sección 20 (docs/29, costo desde la factura) y sección 23
-- (docs/33, + p_copiada_de_id).
-- ============================================================
CREATE OR REPLACE FUNCTION cargar_factura_compra(
  p_proveedor_id UUID,
  p_tipo_comprobante tipo_comprobante_compra,
  p_letra letra_comprobante_compra,
  p_punto_venta TEXT,
  p_numero_comprobante TEXT,
  p_fecha_comprobante DATE,
  p_fecha_fiscal DATE,
  p_forma_pago forma_pago_compra,
  p_items JSONB  -- [{"producto_id":"..."|null,"descripcion":"...","cantidad":1,"precio_unitario_sin_iva":100,"descuento_porcentaje":0,"ubicacion":"local"}]
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_factura_id UUID;
  v_item JSONB;
  v_precio_total_sin_iva NUMERIC;
  v_total_sin_iva NUMERIC := 0;
  v_iva NUMERIC;
  v_total NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  SELECT COALESCE(SUM((i->>'cantidad')::NUMERIC * (i->>'precio_unitario_sin_iva')::NUMERIC
           * (1 - COALESCE((i->>'descuento_porcentaje')::NUMERIC,0)/100.0)), 0)
  INTO v_total_sin_iva
  FROM jsonb_array_elements(p_items) AS i;

  v_iva := ROUND(v_total_sin_iva * 0.21, 2);
  v_total := v_total_sin_iva + v_iva;

  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, letra, punto_venta, numero_comprobante,
         fecha_comprobante, fecha_fiscal, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (p_proveedor_id, p_tipo_comprobante, p_letra, p_punto_venta, p_numero_comprobante,
         p_fecha_comprobante, p_fecha_fiscal, p_forma_pago, v_total_sin_iva, v_iva, v_total, auth.uid())
  RETURNING id INTO v_factura_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_precio_total_sin_iva := ROUND((v_item->>'cantidad')::NUMERIC * (v_item->>'precio_unitario_sin_iva')::NUMERIC
                              * (1 - COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0)/100.0), 2);

    INSERT INTO facturas_compra_items (factura_compra_id, producto_id, descripcion, cantidad,
           precio_unitario_sin_iva, descuento_porcentaje, precio_total_sin_iva, ubicacion)
    VALUES (v_factura_id, NULLIF(v_item->>'producto_id','')::UUID, v_item->>'descripcion',
           (v_item->>'cantidad')::NUMERIC, (v_item->>'precio_unitario_sin_iva')::NUMERIC,
           COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0), v_precio_total_sin_iva,
           COALESCE((v_item->>'ubicacion')::ubicacion_stock, 'local'));

    IF NULLIF(v_item->>'producto_id','') IS NOT NULL THEN
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, referencia_id, usuario_id)
      VALUES ((v_item->>'producto_id')::UUID, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'),
             'compra', (v_item->>'cantidad')::NUMERIC, v_factura_id, auth.uid());

      INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
      VALUES ((v_item->>'producto_id')::UUID, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'), (v_item->>'cantidad')::NUMERIC)
      ON CONFLICT (producto_id, ubicacion)
      DO UPDATE SET cantidad = stock_ubicaciones.cantidad + (v_item->>'cantidad')::NUMERIC;
    END IF;
  END LOOP;

  RETURN v_factura_id;
END;
$$;

-- ============================================================
-- 3. ajustar_stock
-- ============================================================
CREATE OR REPLACE FUNCTION ajustar_stock(
  p_producto_id UUID,
  p_ubicacion ubicacion_stock,
  p_cantidad NUMERIC,
  p_motivo TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para un ajuste de stock';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede ajustar stock manualmente';
  END IF;

  INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, usuario_id)
  VALUES (p_producto_id, p_ubicacion, 'ajuste', p_cantidad, p_motivo, auth.uid());

  INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
  VALUES (p_producto_id, p_ubicacion, p_cantidad)
  ON CONFLICT (producto_id, ubicacion)
  DO UPDATE SET cantidad = stock_ubicaciones.cantidad + p_cantidad;
END;
$$;

-- ============================================================
-- 4. emitir_factura_c
-- Asume que el CAE ya se obtuvo de ARCA ANTES de llamar esta función
-- (esa llamada HTTP va en una Edge Function, Postgres no puede llamarla directo)
-- ============================================================
CREATE OR REPLACE FUNCTION emitir_factura_c(
  p_venta_id UUID,
  p_cae TEXT,
  p_numero_factura TEXT,
  p_punto_venta TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_factura_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF EXISTS (SELECT 1 FROM ventas WHERE id = p_venta_id AND estado = 'facturado') THEN
    RAISE EXCEPTION 'Esta venta ya tiene una Factura C emitida';
  END IF;

  INSERT INTO facturas_c (venta_id, cae, numero_factura, punto_venta, fecha_emision, usuario_id)
  VALUES (p_venta_id, p_cae, p_numero_factura, p_punto_venta, now(), auth.uid())
  RETURNING id INTO v_factura_id;

  UPDATE ventas SET estado = 'facturado' WHERE id = p_venta_id;

  RETURN v_factura_id;
END;
$$;

-- ============================================================
-- 5. registrar_pago_proveedor
-- ⚠ No es la versión vigente: docs/15 agregó los campos de cheque y docs/31 (sección 22) la
-- convirtió en un envoltorio de registrar_pago_proveedor_v2 (imputación + notas de crédito).
-- Impacta en cuentas SOLO si es efectivo o transferencia — cheque y echeq no son
-- plata líquida en Efectivo/MP/Galicia al momento de registrarse (decisión confirmada).
-- ============================================================
CREATE OR REPLACE FUNCTION registrar_pago_proveedor(
  p_proveedor_id UUID,
  p_factura_compra_id UUID,       -- NULL = pago a cuenta general, sin factura puntual
  p_monto NUMERIC,
  p_forma_pago forma_pago_egreso,
  p_origen origen_egreso DEFAULT 'turno',
  p_cierre_caja_id UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_pago_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  INSERT INTO pagos_proveedor (proveedor_id, factura_compra_id, monto, forma_pago, usuario_id)
  VALUES (p_proveedor_id, p_factura_compra_id, p_monto, p_forma_pago, auth.uid())
  RETURNING id INTO v_pago_id;

  INSERT INTO egresos (cierre_caja_id, origen, categoria, monto, descripcion, forma_pago, usuario_id)
  VALUES (p_cierre_caja_id, p_origen, 'pago_proveedor', p_monto, 'Pago a proveedor', p_forma_pago, auth.uid());

  IF p_forma_pago IN ('efectivo', 'transferencia') THEN
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'pago_proveedor', -abs(p_monto), v_pago_id, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = p_forma_pago::text::forma_pago_venta;
  END IF;

  RETURN v_pago_id;
END;
$$;

-- ============================================================
-- 5.1 registrar_egreso_general — gasto sin proveedor (sueldo, servicio, otro)
-- Mismo patrón que registrar_pago_proveedor: cualquier usuario activo, impacto inmediato en la cuenta.
-- Sirve para los dos casos: cajero durante su turno (origen='turno', con cierre_caja_id) y
-- admin desde Caja Gestión (origen='general', sin cierre_caja_id) — es la MISMA función.
-- ============================================================
CREATE OR REPLACE FUNCTION registrar_egreso_general(
  p_categoria categoria_egreso,
  p_monto NUMERIC,
  p_descripcion TEXT,
  p_forma_pago forma_pago_egreso,
  p_origen origen_egreso DEFAULT 'general',
  p_cierre_caja_id UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_egreso_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  -- Gap encontrado en QA: origen='general' es exclusivo de Caja Gestión (admin) — antes solo lo
  -- ocultaba el frontend, ahora también lo rechaza el servidor si alguien lo intenta por API.
  IF p_origen = 'general' AND NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede registrar un egreso de origen general';
  END IF;
  IF p_categoria = 'pago_proveedor' THEN
    RAISE EXCEPTION 'Para pagos a proveedor usá registrar_pago_proveedor, no esta función';
  END IF;
  IF p_descripcion IS NULL OR trim(p_descripcion) = '' THEN
    RAISE EXCEPTION 'La descripción es obligatoria';
  END IF;

  INSERT INTO egresos (cierre_caja_id, origen, categoria, monto, descripcion, forma_pago, usuario_id)
  VALUES (p_cierre_caja_id, p_origen, p_categoria, p_monto, p_descripcion, p_forma_pago, auth.uid())
  RETURNING id INTO v_egreso_id;

  IF p_forma_pago IN ('efectivo', 'transferencia') THEN
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'egreso', -abs(p_monto), v_egreso_id, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = p_forma_pago::text::forma_pago_venta;
  END IF;

  RETURN v_egreso_id;
END;
$$;

-- ============================================================
-- 6. cerrar_caja (sirve para X y para Z)
-- Versión con el merge de docs/21 (apertura de caja, v_monto_base) + docs/22 (venta_pagos) ya
-- aplicado, más el cambio de docs/23: la rama de cuenta corriente lee precio_cobrado en vez de
-- total (hoy da lo mismo porque total = precio_cobrado, pero queda explícito).
-- ⚠ No es la versión vigente: la vigente es la de docs/24 (devoluciones) + SET timezone de
-- docs/28 (día de caja en hora argentina — ver sección 19). Partir de esas, no de esta.
-- ============================================================
CREATE OR REPLACE FUNCTION cerrar_caja(
  p_tipo tipo_cierre,
  p_efectivo_contado NUMERIC DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_cierre_id UUID;
  v_apertura aperturas_caja%ROWTYPE;  -- docs/21: apertura vigente (todavía sin cierre_z_id)
  v_monto_base NUMERIC;               -- docs/21: monto real contado al abrir, suma al efectivo esperado
  v_total_efectivo NUMERIC;
  v_total_transferencia NUMERIC;
  v_total_qr NUMERIC;
  v_total_tarjeta NUMERIC;
  v_total_cuenta_corriente NUMERIC;
  v_total_egresos NUMERIC;          -- total general, todas las formas, para mostrar en el resumen
  v_total_egresos_efectivo NUMERIC; -- corregido en QA: solo esto resta del cajón físico
  v_total_retiros NUMERIC;          -- docs/17: retiros de efectivo del día — también salen del cajón físico
  v_efectivo_esperado NUMERIC;
  v_diferencia NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  SELECT * INTO v_apertura FROM aperturas_caja WHERE cierre_z_id IS NULL ORDER BY abierta_at DESC LIMIT 1;
  v_monto_base := COALESCE(v_apertura.monto_real, 0);

  -- Efectivo/transferencia/QR/tarjeta salen del detalle por parte (venta_pagos, docs/22) — no de
  -- ventas.total, que en una venta combinada no pertenece a un solo medio. venta_pagos.monto ya
  -- sale de precio_cobrado (docs/23), no de precio_oficial.
  SELECT COALESCE(SUM(vp.monto) FILTER (WHERE vp.forma_pago = 'efectivo'), 0),
         COALESCE(SUM(vp.monto) FILTER (WHERE vp.forma_pago = 'transferencia'), 0),
         COALESCE(SUM(vp.monto) FILTER (WHERE vp.forma_pago = 'qr'), 0),
         COALESCE(SUM(vp.monto) FILTER (WHERE vp.forma_pago IN ('tarjeta_debito','tarjeta_credito')), 0)
  INTO v_total_efectivo, v_total_transferencia, v_total_qr, v_total_tarjeta
  FROM venta_pagos vp
  JOIN ventas v ON v.id = vp.venta_id
  WHERE v.created_at::date = current_date AND v.estado <> 'anulada';

  -- Cuenta corriente sigue sin combinarse — se sigue leyendo directo de ventas, ahora de
  -- precio_cobrado (docs/23) en vez de total.
  SELECT COALESCE(SUM(precio_cobrado), 0) INTO v_total_cuenta_corriente
  FROM ventas
  WHERE created_at::date = current_date AND estado <> 'anulada' AND forma_pago = 'cuenta_corriente';

  SELECT COALESCE(SUM(monto), 0) INTO v_total_egresos
  FROM egresos WHERE created_at::date = current_date;

  SELECT COALESCE(SUM(monto), 0) INTO v_total_egresos_efectivo
  FROM egresos WHERE created_at::date = current_date AND forma_pago = 'efectivo';

  SELECT COALESCE(SUM(monto), 0) INTO v_total_retiros
  FROM retiros_caja WHERE fecha = current_date;

  v_efectivo_esperado := v_monto_base + v_total_efectivo - v_total_egresos_efectivo - v_total_retiros;
  v_diferencia := CASE WHEN p_efectivo_contado IS NOT NULL THEN p_efectivo_contado - v_efectivo_esperado ELSE NULL END;

  INSERT INTO cierres_caja (tipo, turno_fecha, total_efectivo, total_transferencia, total_qr, total_tarjeta,
         total_cuenta_corriente, total_egresos, total_retiros, efectivo_esperado, efectivo_contado, diferencia,
         estado_validacion, usuario_id, apertura_id)
  VALUES (p_tipo, current_date, v_total_efectivo, v_total_transferencia, v_total_qr, v_total_tarjeta,
         v_total_cuenta_corriente, v_total_egresos, v_total_retiros, v_efectivo_esperado, p_efectivo_contado, v_diferencia,
         CASE WHEN p_tipo = 'z' THEN 'pendiente_validacion'::estado_cierre_z ELSE NULL END, auth.uid(), v_apertura.id)
  RETURNING id INTO v_cierre_id;

  IF p_tipo = 'z' AND v_apertura.id IS NOT NULL THEN
    UPDATE aperturas_caja SET cierre_z_id = v_cierre_id WHERE id = v_apertura.id;
  END IF;

  RETURN v_cierre_id;
END;
$$;

-- ============================================================
-- 7. validar_cierre_z
-- ============================================================
CREATE OR REPLACE FUNCTION validar_cierre_z(p_cierre_id UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_cierre cierres_caja%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede validar un Cierre Z';
  END IF;

  SELECT * INTO v_cierre FROM cierres_caja WHERE id = p_cierre_id AND tipo = 'z';
  IF NOT FOUND THEN RAISE EXCEPTION 'Cierre Z no encontrado'; END IF;
  IF v_cierre.estado_validacion = 'validado' THEN RAISE EXCEPTION 'Este Cierre Z ya fue validado'; END IF;

  UPDATE cierres_caja SET estado_validacion = 'validado', validado_por = auth.uid(), validado_at = now()
  WHERE id = p_cierre_id;

  -- Efectivo, transferencia y QR se mapean 1 a 1 vía cuenta_forma_pago
  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
  SELECT cfp.cuenta_id, 'cierre_z', v.monto, p_cierre_id, auth.uid()
  FROM (VALUES
    ('efectivo'::forma_pago_venta, v_cierre.total_efectivo),
    ('transferencia'::forma_pago_venta, v_cierre.total_transferencia),
    ('qr'::forma_pago_venta, v_cierre.total_qr)
  ) AS v(forma_pago, monto)
  JOIN cuenta_forma_pago cfp ON cfp.forma_pago = v.forma_pago
  WHERE v.monto > 0;

  -- Tarjeta (débito+crédito, un solo total combinado hoy) va a la misma cuenta que QR (Galicia)
  IF v_cierre.total_tarjeta > 0 THEN
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'cierre_z', v_cierre.total_tarjeta, p_cierre_id, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = 'qr';
  END IF;

  -- Los egresos del día NO se tocan acá — ya impactaron su cuenta en el momento de registrarse
  -- (vía registrar_pago_proveedor / registrar_egreso_general). Volver a restarlos acá los contaría dos veces.
END;
$$;

-- ============================================================
-- 8. cargar_saldos_iniciales
-- ============================================================
CREATE OR REPLACE FUNCTION cargar_saldos_iniciales(
  p_saldos_cuentas JSONB,      -- [{"cuenta_id":"...","monto":150000}]
  p_saldos_proveedores JSONB,  -- [{"proveedor_id":"...","monto":80000}]
  p_saldos_clientes JSONB      -- [{"cliente_id":"...","monto":12000}]
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_item JSONB;
  v_saldo_actual NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede cargar los saldos iniciales';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_saldos_cuentas) LOOP
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, usuario_id)
    VALUES ((v_item->>'cuenta_id')::UUID, 'saldo_inicial', (v_item->>'monto')::NUMERIC, 'Carga inicial del sistema', auth.uid());
  END LOOP;

  -- Corregido en QA: mismo criterio de protección que ya tenía cuentas — no se pisa un saldo ya cargado
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_saldos_proveedores) LOOP
    SELECT saldo_inicial INTO v_saldo_actual FROM proveedores WHERE id = (v_item->>'proveedor_id')::UUID;
    IF v_saldo_actual IS DISTINCT FROM 0 THEN
      RAISE EXCEPTION 'El proveedor % ya tiene un saldo inicial cargado (%) — la carga inicial no se repite, corregilo por separado si hace falta', (v_item->>'proveedor_id'), v_saldo_actual;
    END IF;
    UPDATE proveedores SET saldo_inicial = (v_item->>'monto')::NUMERIC WHERE id = (v_item->>'proveedor_id')::UUID;
  END LOOP;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_saldos_clientes) LOOP
    SELECT saldo_inicial INTO v_saldo_actual FROM clientes WHERE id = (v_item->>'cliente_id')::UUID;
    IF v_saldo_actual IS DISTINCT FROM 0 THEN
      RAISE EXCEPTION 'El cliente % ya tiene un saldo inicial cargado (%) — la carga inicial no se repite, corregilo por separado si hace falta', (v_item->>'cliente_id'), v_saldo_actual;
    END IF;
    UPDATE clientes SET saldo_inicial = (v_item->>'monto')::NUMERIC WHERE id = (v_item->>'cliente_id')::UUID;
  END LOOP;
END;
$$;

-- ============================================================
-- 9. registrar_movimiento_caja_general
-- ============================================================
CREATE OR REPLACE FUNCTION registrar_movimiento_caja_general(
  p_cuenta_id UUID,
  p_monto NUMERIC,
  p_tipo tipo_movimiento_cuenta,
  p_descripcion TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id UUID;
BEGIN
  IF p_tipo NOT IN ('ingreso_manual', 'egreso') THEN
    RAISE EXCEPTION 'Este RPC es solo para movimientos manuales (ingreso_manual o egreso)';
  END IF;
  IF p_descripcion IS NULL OR trim(p_descripcion) = '' THEN
    RAISE EXCEPTION 'La descripción es obligatoria para un movimiento manual de caja';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede registrar movimientos manuales de caja';
  END IF;

  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, usuario_id)
  VALUES (p_cuenta_id, p_tipo, CASE WHEN p_tipo = 'egreso' THEN -abs(p_monto) ELSE abs(p_monto) END, p_descripcion, auth.uid())
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ============================================================
-- 10. registrar_pago_cliente
-- Cobro de una deuda de cuenta corriente — siempre es plata real entrando.
-- ============================================================
CREATE OR REPLACE FUNCTION registrar_pago_cliente(
  p_cliente_id UUID,
  p_venta_id UUID,      -- NULL = pago a cuenta general, sin venta puntual
  p_monto NUMERIC,
  p_forma_pago forma_pago_venta
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_pago_id UUID;
BEGIN
  IF p_forma_pago = 'cuenta_corriente' THEN
    RAISE EXCEPTION 'La forma de pago no puede ser cuenta_corriente para saldar una cuenta corriente';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  INSERT INTO pagos_cliente (cliente_id, venta_id, monto, forma_pago, usuario_id)
  VALUES (p_cliente_id, p_venta_id, p_monto, p_forma_pago, auth.uid())
  RETURNING id INTO v_pago_id;

  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
  SELECT cuenta_id, 'pago_cliente', abs(p_monto), v_pago_id, auth.uid()
  FROM cuenta_forma_pago WHERE forma_pago = p_forma_pago;

  RETURN v_pago_id;
END;
$$;

-- ============================================================
-- 11. transferir_entre_cuentas
-- Mover plata de una cuenta a otra (ej. retirar de Efectivo y depositar en Mercado Pago).
-- Dos filas con la misma referencia — para que se vean como una sola operación en el Historial.
-- ============================================================
CREATE OR REPLACE FUNCTION transferir_entre_cuentas(
  p_cuenta_origen_id UUID,
  p_cuenta_destino_id UUID,
  p_monto NUMERIC,
  p_descripcion TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_referencia UUID := gen_random_uuid();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede transferir entre cuentas';
  END IF;
  IF p_cuenta_origen_id = p_cuenta_destino_id THEN
    RAISE EXCEPTION 'La cuenta de origen y destino no pueden ser la misma';
  END IF;
  IF p_monto <= 0 THEN
    RAISE EXCEPTION 'El monto de la transferencia debe ser positivo';
  END IF;
  IF p_descripcion IS NULL OR trim(p_descripcion) = '' THEN
    RAISE EXCEPTION 'La descripción es obligatoria para una transferencia entre cuentas';
  END IF;

  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, referencia_id, usuario_id)
  VALUES (p_cuenta_origen_id, 'transferencia_interna', -abs(p_monto), p_descripcion, v_referencia, auth.uid());

  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, referencia_id, usuario_id)
  VALUES (p_cuenta_destino_id, 'transferencia_interna', abs(p_monto), p_descripcion, v_referencia, auth.uid());

  RETURN v_referencia;
END;
$$;

-- ============================================================
-- 12. editar_movimiento_cuenta
-- "Editar" nunca pisa la fila original — la anula con una fila inversa y crea la corregida.
-- Ambas quedan visibles en el Historial (el trigger de auditoría dispara con cada INSERT).
-- ============================================================
CREATE OR REPLACE FUNCTION editar_movimiento_cuenta(
  p_movimiento_id UUID,
  p_monto_nuevo NUMERIC,
  p_descripcion_nueva TEXT,
  p_motivo TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_original movimientos_cuenta%ROWTYPE;
  v_nuevo_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede editar un movimiento de cuenta';
  END IF;
  IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para editar un movimiento';
  END IF;

  SELECT * INTO v_original FROM movimientos_cuenta WHERE id = p_movimiento_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Movimiento no encontrado'; END IF;

  -- Anula el original (contra-asiento exacto)
  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, revierte_movimiento_id, usuario_id)
  VALUES (v_original.cuenta_id, v_original.tipo, -1 * v_original.monto,
          'Corrección: ' || p_motivo, p_movimiento_id, auth.uid());

  -- Crea la versión corregida
  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, revierte_movimiento_id, usuario_id)
  VALUES (v_original.cuenta_id, v_original.tipo, p_monto_nuevo,
          COALESCE(p_descripcion_nueva, v_original.descripcion), p_movimiento_id, auth.uid())
  RETURNING id INTO v_nuevo_id;

  RETURN v_nuevo_id;
END;
$$;

-- ============================================================
-- 13. eliminar_movimiento_cuenta
-- "Eliminar" nunca hace DELETE — inserta el contra-asiento exacto, dejando el efecto en cero.
-- ============================================================
CREATE OR REPLACE FUNCTION eliminar_movimiento_cuenta(
  p_movimiento_id UUID,
  p_motivo TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_original movimientos_cuenta%ROWTYPE;
  v_nuevo_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede eliminar un movimiento de cuenta';
  END IF;
  IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para eliminar un movimiento';
  END IF;

  SELECT * INTO v_original FROM movimientos_cuenta WHERE id = p_movimiento_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Movimiento no encontrado'; END IF;

  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, revierte_movimiento_id, usuario_id)
  VALUES (v_original.cuenta_id, v_original.tipo, -1 * v_original.monto,
          'Eliminación: ' || p_motivo, p_movimiento_id, auth.uid())
  RETURNING id INTO v_nuevo_id;

  RETURN v_nuevo_id;
END;
$$;

-- ============================================================
-- 10. editar_factura_compra — exclusivo Gestión, solo campos descriptivos
-- No permite tocar ítems/montos: si el error está en cantidad/precio, se anula y se recarga.
-- ============================================================
CREATE OR REPLACE FUNCTION editar_factura_compra(
  p_factura_id UUID,
  p_tipo_comprobante tipo_comprobante_compra DEFAULT NULL,
  p_letra letra_comprobante_compra DEFAULT NULL,
  p_punto_venta TEXT DEFAULT NULL,
  p_numero_comprobante TEXT DEFAULT NULL,
  p_fecha_comprobante DATE DEFAULT NULL,
  p_fecha_fiscal DATE DEFAULT NULL,
  p_forma_pago forma_pago_compra DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede editar una factura de compra ya cargada';
  END IF;
  IF EXISTS (SELECT 1 FROM facturas_compra WHERE id = p_factura_id AND anulada = true) THEN
    RAISE EXCEPTION 'Esta factura está anulada, no se edita';
  END IF;

  UPDATE facturas_compra SET
    tipo_comprobante = COALESCE(p_tipo_comprobante, tipo_comprobante),
    letra = COALESCE(p_letra, letra),
    punto_venta = COALESCE(p_punto_venta, punto_venta),
    numero_comprobante = COALESCE(p_numero_comprobante, numero_comprobante),
    fecha_comprobante = COALESCE(p_fecha_comprobante, fecha_comprobante),
    fecha_fiscal = COALESCE(p_fecha_fiscal, fecha_fiscal),
    forma_pago = COALESCE(p_forma_pago, forma_pago)
  WHERE id = p_factura_id;
  -- El trigger de auditoría genérico ya deja el antes/después completo — no hace falta nada más acá.
END;
$$;

-- ============================================================
-- 11. anular_factura_compra — exclusivo Gestión, revierte el stock que había sumado
-- ============================================================
CREATE OR REPLACE FUNCTION anular_factura_compra(p_factura_id UUID, p_motivo TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_item RECORD;
  v_ya_anulada BOOLEAN;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede anular una factura de compra';
  END IF;
  IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para anular una factura de compra';
  END IF;

  SELECT anulada INTO v_ya_anulada FROM facturas_compra WHERE id = p_factura_id;
  IF v_ya_anulada IS NULL THEN
    RAISE EXCEPTION 'Factura de compra no encontrada';
  END IF;
  IF v_ya_anulada THEN
    RAISE EXCEPTION 'Esta factura ya estaba anulada';
  END IF;
  IF EXISTS (SELECT 1 FROM pagos_proveedor WHERE factura_compra_id = p_factura_id) THEN
    RAISE EXCEPTION 'Esta factura ya tiene pagos registrados — resolvé esos pagos antes de anularla';
  END IF;

  FOR v_item IN
    SELECT producto_id, cantidad, ubicacion FROM facturas_compra_items
    WHERE factura_compra_id = p_factura_id AND producto_id IS NOT NULL
  LOOP
    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
    VALUES (v_item.producto_id, v_item.ubicacion, 'ajuste', -1 * v_item.cantidad,
            'Anulación de factura de compra: ' || p_motivo, p_factura_id, auth.uid());

    UPDATE stock_ubicaciones SET cantidad = cantidad - v_item.cantidad
    WHERE producto_id = v_item.producto_id AND ubicacion = v_item.ubicacion;
  END LOOP;

  UPDATE facturas_compra SET anulada = true WHERE id = p_factura_id;

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, nota, usuario_id)
  VALUES ('facturas_compra', p_factura_id, 'anulacion', p_motivo, auth.uid());
END;
$$;
```

**Seed a ejecutar una vez, después de crear las funciones** (cuentas reales + su mapeo a formas de pago):

```sql
INSERT INTO cuentas (nombre) VALUES ('Efectivo'), ('Mercado Pago'), ('Galicia')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO cuenta_forma_pago (forma_pago, cuenta_id) VALUES
  ('efectivo',        (SELECT id FROM cuentas WHERE nombre = 'Efectivo')),
  ('transferencia',   (SELECT id FROM cuentas WHERE nombre = 'Mercado Pago')),
  ('qr',              (SELECT id FROM cuentas WHERE nombre = 'Galicia')),
  ('tarjeta_debito',  (SELECT id FROM cuentas WHERE nombre = 'Galicia')),
  ('tarjeta_credito', (SELECT id FROM cuentas WHERE nombre = 'Galicia'))
ON CONFLICT (forma_pago) DO NOTHING;
```

---

## 9. Vistas de saldo (facturas, proveedores y clientes)

Para no recalcular esto a mano en el frontend cada vez — la fuente de verdad vive en la base:

> ⚠ `facturas_compra_saldo` y `proveedores_saldo` de abajo no son las vigentes: docs/31 (sección 22) las calcula desde `pagos_proveedor_aplicaciones`, hace que las notas de crédito resten y agrega `total_aplicado`, `credito_disponible` y `estado`.

```sql
-- Saldo pendiente por cada factura de compra puntual
CREATE OR REPLACE VIEW facturas_compra_saldo AS
SELECT
  fc.*,
  COALESCE(pagado.total_pagado, 0) AS total_pagado,
  fc.total - COALESCE(pagado.total_pagado, 0) AS saldo_pendiente
FROM facturas_compra fc
LEFT JOIN (
  SELECT factura_compra_id, SUM(monto) AS total_pagado
  FROM pagos_proveedor
  WHERE factura_compra_id IS NOT NULL
  GROUP BY factura_compra_id
) pagado ON pagado.factura_compra_id = fc.id;

-- Saldo total por proveedor (incluye pagos a cuenta general, sin factura puntual)
CREATE OR REPLACE VIEW proveedores_saldo AS
SELECT
  p.*,
  p.saldo_inicial
    + COALESCE(facturado.total_facturado, 0)
    - COALESCE(pagado.total_pagado, 0) AS saldo_actual
FROM proveedores p
LEFT JOIN (
  SELECT proveedor_id, SUM(total) AS total_facturado
  FROM facturas_compra WHERE anulada = false GROUP BY proveedor_id
) facturado ON facturado.proveedor_id = p.id
LEFT JOIN (
  SELECT proveedor_id, SUM(monto) AS total_pagado
  FROM pagos_proveedor GROUP BY proveedor_id
) pagado ON pagado.proveedor_id = p.id;

-- Saldo de cuenta corriente por cliente
CREATE OR REPLACE VIEW clientes_saldo AS
SELECT
  c.*,
  c.saldo_inicial
    + COALESCE(ventas_cta.total_cuenta_corriente, 0)
    - COALESCE(pagos.total_pagado, 0) AS saldo_actual
FROM clientes c
LEFT JOIN (
  SELECT cliente_id, SUM(total) AS total_cuenta_corriente
  FROM ventas WHERE forma_pago = 'cuenta_corriente' AND estado <> 'anulada'
  GROUP BY cliente_id
) ventas_cta ON ventas_cta.cliente_id = c.id
LEFT JOIN (
  SELECT cliente_id, SUM(monto) AS total_pagado
  FROM pagos_cliente GROUP BY cliente_id
) pagos ON pagos.cliente_id = c.id;

-- Saldo actual por cuenta (Efectivo, Mercado Pago, Galicia) — para el dashboard "Resumen Cuentas"
CREATE OR REPLACE VIEW cuentas_saldo AS
SELECT
  c.*,
  COALESCE(SUM(mc.monto), 0) AS saldo_actual
FROM cuentas c
LEFT JOIN movimientos_cuenta mc ON mc.cuenta_id = c.id
GROUP BY c.id;
```

Ambas vistas heredan el RLS de las tablas que consultan — no hace falta política propia. Usar `facturas_compra_saldo` para el detalle de una factura (módulo 6) y `proveedores_saldo` para el listado con saldo visible y para el resumen de Caja Gestión (módulo 7.1).

## 10. Tipos TypeScript derivados

```typescript
export type RolUsuario = 'admin' | 'cajero'
export type EstadoProducto = 'activo' | 'inactivo'
export type UbicacionStock = 'local' | 'deposito'
export type FormaPagoVenta = 'efectivo' | 'transferencia' | 'qr' | 'tarjeta_debito' | 'tarjeta_credito' | 'cuenta_corriente' | 'combinado'
export type EstadoComprobante = 'sin_facturar' | 'facturado' | 'anulada'

export type Producto = {
  id: string
  nombre: string
  descripcion: string | null
  codigo_barras: string | null
  codigo_interno: string | null
  proveedor_id: string | null
  marca: string | null
  costo: number
  margen_1: number
  margen_2: number
  iva_porcentaje: number
  precio_calculado: number    // columna generada (sección 20) — fórmula exacta, 2 decimales
  precio_venta: number        // columna generada — redondeo escalonado (sección 21), nunca escribir
  stock_minimo: number
  estado: EstadoProducto
  created_at: string
  updated_at: string
}

export type StockUbicacion = {
  id: string
  producto_id: string
  ubicacion: UbicacionStock
  cantidad: number
}

export type Venta = {
  id: string
  numero: number
  cliente_id: string | null   // null = consumidor final
  forma_pago: FormaPagoVenta  // 'combinado' = ver detalle en VentaPago (venta_pagos)
  subtotal: number
  descuento_porcentaje: number
  recargo_porcentaje: number
  total: number
  estado: EstadoComprobante
  nota: string | null
  terminal_id: string
  usuario_id: string
  created_at: string
}

export type VentaPago = {
  id: string
  venta_id: string
  forma_pago: FormaPagoVenta  // nunca 'cuenta_corriente' ni 'combinado' acá
  monto: number
  usuario_id: string
  created_at: string
}

export type FacturaC = {
  id: string
  venta_id: string             // 1:1 con Venta
  cae: string | null
  numero_factura: string | null
  punto_venta: string | null
  fecha_emision: string | null
  pdf_url: string | null
  enviado_a: string | null
  usuario_id: string
  created_at: string
}
```

export type TipoMovimientoCuenta = 'saldo_inicial' | 'venta' | 'pago_cliente' | 'pago_proveedor' | 'egreso' | 'ingreso_manual' | 'cierre_z' | 'transferencia_interna'

export type CategoriaEgreso = 'pago_proveedor' | 'sueldo' | 'servicio' | 'otro' | 'agua' | 'descartables' | 'super'
// agua/descartables/super agregadas en docs/13_categorias_egresos_local.sql — categorías de
// turno para Virikyna-Local; sueldo/servicio quedan como categorías de Virikyna-Gestión.

export type Cuenta = {
  id: string
  nombre: string
  created_at: string
}

export type MovimientoCuenta = {
  id: string
  cuenta_id: string
  tipo: TipoMovimientoCuenta
  monto: number          // positivo = ingreso, negativo = egreso
  descripcion: string | null
  referencia_id: string | null
  revierte_movimiento_id: string | null
  usuario_id: string
  created_at: string
}

export type TipoAccionAuditoria = 'alta' | 'edicion' | 'eliminacion' | 'anulacion' | 'reversion' | 'nota_correccion'

export type Auditoria = {
  id: string
  tabla_afectada: string
  registro_id: string
  accion: TipoAccionAuditoria
  valores_anteriores: Record<string, unknown> | null
  valores_nuevos: Record<string, unknown> | null
  usuario_id: string
  revierte_auditoria_id: string | null
  nota: string | null
  created_at: string
}

*(Derivar el resto de los tipos — `Proveedor`, `Cliente`, `FacturaCompra`, `CierreCaja`, `Egreso`, etc. — con el mismo criterio al momento de escribirlos, directo desde este schema, no antes.)*

---

## 11. Correcciones de la primera ronda de QA

Todo esto se detectó testeando el sistema ya construido — ver `fixes-post-qa-ronda-1.md` para el detalle de cada bug y su validación. Se documenta acá para que quede en la fuente de verdad del schema, no solo en el archivo de fixes puntual.

**Triggers de protección de margen** (RLS no puede comparar valor viejo vs. nuevo — hace falta trigger):

```sql
CREATE OR REPLACE FUNCTION fn_proteger_margen_producto() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF (NEW.margen_1 IS DISTINCT FROM OLD.margen_1) OR (NEW.margen_2 IS DISTINCT FROM OLD.margen_2) THEN
    IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
      RAISE EXCEPTION 'Solo un administrador puede modificar el margen de un producto';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_proteger_margen_producto ON productos;
CREATE TRIGGER trg_proteger_margen_producto BEFORE UPDATE ON productos
  FOR EACH ROW EXECUTE FUNCTION fn_proteger_margen_producto();

CREATE OR REPLACE FUNCTION fn_proteger_margen_proveedor() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF (NEW.margen_1_default IS DISTINCT FROM OLD.margen_1_default) OR (NEW.margen_2_default IS DISTINCT FROM OLD.margen_2_default) THEN
    IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
      RAISE EXCEPTION 'Solo un administrador puede modificar el margen por defecto de un proveedor';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_proteger_margen_proveedor ON proveedores;
CREATE TRIGGER trg_proteger_margen_proveedor BEFORE UPDATE ON proveedores
  FOR EACH ROW EXECUTE FUNCTION fn_proteger_margen_proveedor();
```

**Trigger de protección de eliminación de cliente** (la regla "con historial no se elimina, solo se inactiva" vivía solo en el frontend):

```sql
CREATE OR REPLACE FUNCTION fn_proteger_eliminacion_cliente() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM ventas WHERE cliente_id = OLD.id)
     OR EXISTS (SELECT 1 FROM pagos_cliente WHERE cliente_id = OLD.id) THEN
    RAISE EXCEPTION 'Este cliente tiene historial — no se puede eliminar, solo inactivar';
  END IF;
  RETURN OLD;
END;
$$;
DROP TRIGGER IF EXISTS trg_proteger_eliminacion_cliente ON clientes;
CREATE TRIGGER trg_proteger_eliminacion_cliente BEFORE DELETE ON clientes
  FOR EACH ROW EXECUTE FUNCTION fn_proteger_eliminacion_cliente();
```

**RPC de actualización masiva de precios** (estaba pedida desde el doc 04 original, nunca se había construido). ⚠ La versión vigente es la de la sección 24 (docs/34): también actualiza `precio_manual`.

```sql
CREATE OR REPLACE FUNCTION actualizar_precios_masivo(
  p_porcentaje NUMERIC,
  p_proveedor_id UUID DEFAULT NULL,
  p_producto_ids UUID[] DEFAULT NULL
) RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_count INTEGER;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF (p_proveedor_id IS NULL) = (p_producto_ids IS NULL) THEN
    RAISE EXCEPTION 'Especificá exactamente uno: proveedor_id o producto_ids';
  END IF;
  UPDATE productos
  SET costo = ROUND(costo * (1 + p_porcentaje/100.0), 2)
  WHERE (p_proveedor_id IS NOT NULL AND proveedor_id = p_proveedor_id)
     OR (p_producto_ids IS NOT NULL AND id = ANY(p_producto_ids));
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
```
Aplica el % sobre `costo`, no sobre el precio final — `precio_venta` es columna generada, se recalcula sola.

**Edge Function `admin-usuarios`** (vive fuera del SQL, en Supabase Edge Functions — `supabase/functions/admin-usuarios/index.ts`, deploy con `supabase functions deploy admin-usuarios`). Reemplaza cualquier `INSERT`/`UPDATE` directo a `perfiles` o a Supabase Auth desde el cliente para: crear usuario, blanquear contraseña, desactivar usuario. Valida rol admin del lado del servidor antes de usar `service_role` — el código completo está en `fixes-post-qa-ronda-1.md`. Usuarios reales, uno por persona (Alicia, Ana Julia, Jose, Ale, Belu) — nunca cuentas compartidas por rol, porque el módulo 10 (Historial y Auditoría) necesita poder identificar a la persona, no solo el rol.

## 12. Fecha editable en egresos (módulo Egresos)

Agregado al construir el módulo de primer nivel **Egresos** (docs/04_modulos_y_funciones.md). Hasta acá `egresos` solo tenía `created_at` — el timestamp de cuándo se cargó la fila en el sistema. Para un egreso general (sueldo, servicio, otro) cargado desde Gestión, eso no alcanza: a veces se carga días después de haber ocurrido el gasto. Se agrega `fecha` (DATE), con default hoy pero editable en el formulario, sin tocar `created_at`. El frontend la muestra en formato argentino `dd-MM-YYYY` (`formatFechaCorta`, `packages/shared/lib/format.ts`).

Solo se toca `registrar_egreso_general` — el único punto de entrada que ahora expone la fecha editable en una pantalla (Egresos, exclusivo Gestión). `registrar_pago_proveedor` queda sin cambios: sus filas en `egresos` (categoría `pago_proveedor`) siguen tomando `fecha = CURRENT_DATE` por el `DEFAULT` de la columna, ya que no hay pantalla que permita backdatearlas.

Ejecutar en el SQL Editor de Supabase (proyecto ccpinvtleqlsukcqnili), después de 06 (y 09/10 si ya se corrieron). Correr una sola vez.

```sql
-- 1. Columna nueva — se backfillea con la fecha de created_at para las filas existentes
--    (más preciso que dejarlas todas con la fecha del día de la migración).
ALTER TABLE egresos ADD COLUMN fecha DATE;
UPDATE egresos SET fecha = created_at::date WHERE fecha IS NULL;
ALTER TABLE egresos ALTER COLUMN fecha SET NOT NULL;
ALTER TABLE egresos ALTER COLUMN fecha SET DEFAULT CURRENT_DATE;

-- 2. registrar_egreso_general — agrega p_fecha (editable), default hoy. Quien no lo manda
--    (Virikyna Local / Inventario, egreso de turno) sigue funcionando igual, toma CURRENT_DATE.
CREATE OR REPLACE FUNCTION registrar_egreso_general(
  p_categoria categoria_egreso,
  p_monto NUMERIC,
  p_descripcion TEXT,
  p_forma_pago forma_pago_egreso,
  p_origen origen_egreso DEFAULT 'general',
  p_cierre_caja_id UUID DEFAULT NULL,
  p_fecha DATE DEFAULT CURRENT_DATE
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_egreso_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF p_origen = 'general' AND NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede registrar un egreso de origen general';
  END IF;
  IF p_categoria = 'pago_proveedor' THEN
    RAISE EXCEPTION 'Para pagos a proveedor usá registrar_pago_proveedor, no esta función';
  END IF;
  IF p_descripcion IS NULL OR trim(p_descripcion) = '' THEN
    RAISE EXCEPTION 'La descripción es obligatoria';
  END IF;
  IF p_fecha IS NULL THEN
    RAISE EXCEPTION 'La fecha del egreso es obligatoria';
  END IF;

  INSERT INTO egresos (cierre_caja_id, origen, categoria, monto, descripcion, forma_pago, usuario_id, fecha)
  VALUES (p_cierre_caja_id, p_origen, p_categoria, p_monto, p_descripcion, p_forma_pago, auth.uid(), p_fecha)
  RETURNING id INTO v_egreso_id;

  IF p_forma_pago IN ('efectivo', 'transferencia') THEN
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'egreso', -abs(p_monto), v_egreso_id, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = p_forma_pago::text::forma_pago_venta;
  END IF;

  RETURN v_egreso_id;
END;
$$;
```

## 13. Margen por proveedor al reingresar stock (carga de factura de compra)

Hasta acá `cargar_factura_compra` (sección 8, RPC 2) no tocaba el margen del producto en absoluto — cargar una factura solo movía stock (`movimientos_stock`, `stock_ubicaciones`) y registraba la compra; `productos.costo`/`margen_1`/`margen_2` quedaban totalmente desacoplados, se editaban aparte y a mano desde la ficha del producto.

Regla de negocio agregada: cuando un ítem de la factura está vinculado a un producto existente (`producto_id`), se compara el proveedor de la factura (`p_proveedor_id`) contra el proveedor guardado en ese momento en `productos.proveedor_id`:

- **Mismo proveedor** → no se toca `margen_1`/`margen_2`. El producto conserva el margen que tenía, incluida cualquier excepción manual que le hayan cargado a mano.
- **Proveedor nuevo** (el producto cambió de proveedor respecto de la última vez) → se actualiza `productos.proveedor_id` al proveedor de la factura y se pisan `margen_1`/`margen_2` con `margen_1_default`/`margen_2_default` del proveedor nuevo, sobrescribiendo el margen anterior (incluida cualquier excepción manual previa — el cambio de proveedor es intencional y gana).

No se toca el cálculo de `precio_venta` (columna generada, sección 3) ni ninguna otra regla de stock de esta función — solo se agrega esta comparación dentro del loop de ítems que ya existía.

> ⚠ La versión vigente de `cargar_factura_compra` es la de la sección 20 (docs/29): mantiene esta regla de proveedor y márgenes y además actualiza `productos.costo` desde la factura.

El trigger `trg_proteger_margen_producto` (sección 11) bloquea cualquier UPDATE a `margen_1`/`margen_2` si quien ejecuta la sesión no es admin. Acá el cambio es automático, disparado por la regla "cambió de proveedor" — no una edición manual — así que necesita su propia válvula de escape, con el mismo patrón que ya usa `fn_auditoria_generica` (`virikyna.suppress_audit`, sección 10) pero con su propio flag, para NO desactivar la auditoría: el `UPDATE` sigue quedando registrado en `auditoria` como `'edicion'` normal (así el Historial puede mostrar por qué cambió el margen).

Ejecutar en el SQL Editor de Supabase (proyecto ccpinvtleqlsukcqnili), después de 06 (y 09/10/12 si ya se corrieron). Correr una sola vez.

```sql
-- 1. Válvula de escape en fn_proteger_margen_producto para la herencia automática de margen
--    por cambio de proveedor (no es una edición manual, no debe exigir rol admin).
CREATE OR REPLACE FUNCTION fn_proteger_margen_producto() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF (NEW.margen_1 IS DISTINCT FROM OLD.margen_1) OR (NEW.margen_2 IS DISTINCT FROM OLD.margen_2) THEN
    IF current_setting('virikyna.margen_auto_herencia', true) = 'true' THEN
      RETURN NEW;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
      RAISE EXCEPTION 'Solo un administrador puede modificar el margen de un producto';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- 2. cargar_factura_compra — agrega la comparación de proveedor por ítem con producto_id.
--    Mismo proveedor: no toca margen_1/margen_2. Proveedor nuevo: hereda margen_1_default/
--    margen_2_default del proveedor nuevo y actualiza productos.proveedor_id.
CREATE OR REPLACE FUNCTION cargar_factura_compra(
  p_proveedor_id UUID,
  p_tipo_comprobante tipo_comprobante_compra,
  p_letra letra_comprobante_compra,
  p_punto_venta TEXT,
  p_numero_comprobante TEXT,
  p_fecha_comprobante DATE,
  p_fecha_fiscal DATE,
  p_forma_pago forma_pago_compra,
  p_items JSONB  -- [{"producto_id":"..."|null,"descripcion":"...","cantidad":1,"precio_unitario_sin_iva":100,"descuento_porcentaje":0,"ubicacion":"local"}]
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_factura_id UUID;
  v_item JSONB;
  v_precio_total_sin_iva NUMERIC;
  v_total_sin_iva NUMERIC := 0;
  v_iva NUMERIC;
  v_total NUMERIC;
  v_producto_id UUID;
  v_producto_proveedor_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  SELECT COALESCE(SUM((i->>'cantidad')::NUMERIC * (i->>'precio_unitario_sin_iva')::NUMERIC
           * (1 - COALESCE((i->>'descuento_porcentaje')::NUMERIC,0)/100.0)), 0)
  INTO v_total_sin_iva
  FROM jsonb_array_elements(p_items) AS i;

  v_iva := ROUND(v_total_sin_iva * 0.21, 2);
  v_total := v_total_sin_iva + v_iva;

  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, letra, punto_venta, numero_comprobante,
         fecha_comprobante, fecha_fiscal, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (p_proveedor_id, p_tipo_comprobante, p_letra, p_punto_venta, p_numero_comprobante,
         p_fecha_comprobante, p_fecha_fiscal, p_forma_pago, v_total_sin_iva, v_iva, v_total, auth.uid())
  RETURNING id INTO v_factura_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_precio_total_sin_iva := ROUND((v_item->>'cantidad')::NUMERIC * (v_item->>'precio_unitario_sin_iva')::NUMERIC
                              * (1 - COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0)/100.0), 2);

    INSERT INTO facturas_compra_items (factura_compra_id, producto_id, descripcion, cantidad,
           precio_unitario_sin_iva, descuento_porcentaje, precio_total_sin_iva, ubicacion)
    VALUES (v_factura_id, NULLIF(v_item->>'producto_id','')::UUID, v_item->>'descripcion',
           (v_item->>'cantidad')::NUMERIC, (v_item->>'precio_unitario_sin_iva')::NUMERIC,
           COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0), v_precio_total_sin_iva,
           COALESCE((v_item->>'ubicacion')::ubicacion_stock, 'local'));

    v_producto_id := NULLIF(v_item->>'producto_id','')::UUID;

    IF v_producto_id IS NOT NULL THEN
      SELECT proveedor_id INTO v_producto_proveedor_id FROM productos WHERE id = v_producto_id;

      IF v_producto_proveedor_id IS DISTINCT FROM p_proveedor_id THEN
        PERFORM set_config('virikyna.margen_auto_herencia', 'true', true);
        UPDATE productos
        SET proveedor_id = p_proveedor_id,
            margen_1 = (SELECT margen_1_default FROM proveedores WHERE id = p_proveedor_id),
            margen_2 = (SELECT margen_2_default FROM proveedores WHERE id = p_proveedor_id),
            updated_at = now()
        WHERE id = v_producto_id;
        PERFORM set_config('virikyna.margen_auto_herencia', 'false', true);
      END IF;

      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, referencia_id, usuario_id)
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'),
             'compra', (v_item->>'cantidad')::NUMERIC, v_factura_id, auth.uid());

      INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'), (v_item->>'cantidad')::NUMERIC)
      ON CONFLICT (producto_id, ubicacion)
      DO UPDATE SET cantidad = stock_ubicaciones.cantidad + (v_item->>'cantidad')::NUMERIC;
    END IF;
  END LOOP;

  RETURN v_factura_id;
END;
$$;
```

---

## 14. Notas internas (módulo Notas — docs/04_modulos_y_funciones.md módulo 11)

Tabla compartida 1:1 por Virikyna Local y Virikyna Gestión — pizarrón tipo post-it, sin jerarquía de roles (a diferencia del resto del sistema, admin y cajero tienen exactamente los mismos permisos acá). SQL completo y ejecutable en `docs/16_notas_internas.sql`.

```sql
CREATE TABLE notas_internas (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  mensaje TEXT NOT NULL,
  autor_id UUID NOT NULL REFERENCES perfiles(id),
  archivada BOOLEAN NOT NULL DEFAULT false,
  archivada_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Mismo patrón "_todos" que ventas/egresos/retiros_caja (sección 5).
ALTER TABLE notas_internas ENABLE ROW LEVEL SECURITY;
CREATE POLICY "notas_internas_todos" ON notas_internas FOR ALL USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
);

-- Nombre del autor ya resuelto: perfiles solo expone la fila propia por RLS (sección 5, regla de
-- oro), así que un cajero no puede ver el nombre de otro usuario con un join directo desde el
-- cliente. Esta vista hereda el RLS de notas_internas, mismo criterio que las vistas de la
-- sección 9 — no hace falta política propia.
CREATE OR REPLACE VIEW notas_internas_con_autor AS
SELECT n.*, p.nombre AS autor_nombre
FROM notas_internas n
JOIN perfiles p ON p.id = n.autor_id;
GRANT SELECT ON notas_internas_con_autor TO authenticated;
```

Sin trigger de auditoría a propósito: una nota interna es texto libre sin impacto contable ni operativo (no aplica la sección 6, ni las reglas de reversibilidad de la sección 7 / módulo 10 de `04_modulos_y_funciones.md`).

**Tipos TypeScript** (`packages/shared/types/database.ts`):

```typescript
export type NotaInterna = {
  id: string
  mensaje: string
  autor_id: string
  archivada: boolean
  archivada_at: string | null
  created_at: string
}

export type NotaInternaConAutor = NotaInterna & {
  autor_nombre: string
}
```

---

## 15. Notas internas por origen — Local vs Gestión (módulo Notas, docs/04_modulos_y_funciones.md módulo 11)

Hasta acá `notas_internas` era una sola bandeja compartida 1:1: una nota creada desde cualquiera de las dos apps aparecía igual en la otra (sección 14). Se agrega `origen` para separarlas: una nota de Virikyna Gestión ya no llega a Virikyna Local, ni al revés — y un cajero no puede ver ni crear una nota de origen `gestion` ni a nivel de RLS. SQL completo en `docs/16_notas_internas.sql` (sección "ACTUALIZACIÓN", al final del archivo).

```sql
ALTER TABLE notas_internas ADD COLUMN origen TEXT NOT NULL DEFAULT 'local'
  CHECK (origen IN ('local', 'gestion'));

-- Recrear la vista: `notas_internas_con_autor` (sección 14) usa `SELECT n.*`, que fija la lista
-- de columnas al momento en que se ejecuta el CREATE OR REPLACE — no se actualiza sola cuando la
-- tabla gana una columna nueva. `origen` se agrega al final de la tabla, así que con `n.*` le
-- tomaría el lugar a `autor_nombre` en esa posición — y Postgres rechaza un CREATE OR REPLACE
-- VIEW que le cambia el nombre a una columna existente (error 42P16). Por eso DROP + CREATE con
-- columnas explícitas, `autor_nombre` al final a propósito.
DROP VIEW IF EXISTS notas_internas_con_autor;
CREATE VIEW notas_internas_con_autor AS
SELECT n.id, n.mensaje, n.autor_id, n.origen, n.archivada, n.archivada_at, n.created_at,
       p.nombre AS autor_nombre
FROM notas_internas n
JOIN perfiles p ON p.id = n.autor_id;
GRANT SELECT ON notas_internas_con_autor TO authenticated;

-- Reemplaza la policy de la sección 14: mismo patrón "_todos" (EXISTS contra `perfiles`, sin
-- función helper), pero origen='gestion' queda restringido a admin.
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
```

Las notas ya existentes quedan como `'local'` por el `DEFAULT` (la clasificación que no le saca visibilidad a nadie que ya la tenía) — revisar a mano si alguna era en realidad de Gestión y reclasificarla con un `UPDATE` puntual por id.

**Verificado en el proyecto real:** el bloque de arriba, corrido de punta a punta, deja la vista y la policy correctas — probado creando una nota `origen='gestion'` logueado como admin. Pendiente de probar (no se hizo en esta ronda): loguear como cajero en Virikyna Local y confirmar que ninguna nota `origen='gestion'` aparece — Gestión ya bloquea a un cajero antes de esto, al nivel de login (`AuthContext.tsx` corta si `rol !== 'admin'`).

**El frontend no confía solo en RLS:** cada app además filtra explícito por su propio origen en la query y lo fija al crear, sin selector ni dependencia del rol logueado.

- Virikyna Local (`src/pages/Notas/NotasPage.tsx`): `.eq('origen', 'local')` al leer. `NuevaNotaModal.tsx`: `insert({ ..., origen: 'local' })`.
- Virikyna Gestión (`src/pages/Notas/NotasPage.tsx`): `.eq('origen', 'gestion')` al leer. `NuevaNotaModal.tsx`: `insert({ ..., origen: 'gestion' })`.

**Tipos TypeScript** (`packages/shared/types/database.ts`):

```typescript
export type OrigenNota = 'local' | 'gestion'

export type NotaInterna = {
  id: string
  mensaje: string
  autor_id: string
  origen: OrigenNota
  archivada: boolean
  archivada_at: string | null
  created_at: string
}
```

## 16. Resumen de ventas por día para el Dashboard (Virikyna Gestión)

El Dashboard de Gestión traía las ventas crudas de los últimos 7 días y las sumaba en el navegador, con un rango `desde`/`hasta` armado como texto sin zona horaria. Como la base está en UTC, "hoy 23:59:59" se leía como 20:59:59 hora argentina y las ventas de después de las 21:00 (AR) no contaban en el día de hoy. Ahora la agregación la hace la base, con el día calculado en hora argentina explícita. SQL completo en `docs/25_dashboard_resumen.sql`.

```sql
CREATE OR REPLACE FUNCTION dashboard_ventas_por_dia(p_desde DATE, p_hasta DATE)
RETURNS TABLE (fecha DATE, total NUMERIC, cantidad INT)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  WITH ventas_rango AS (
    SELECT (v.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS dia,
           v.precio_cobrado
    FROM ventas v
    WHERE v.estado <> 'anulada'
      AND v.created_at >= (p_desde::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
      AND v.created_at <  ((p_hasta + 1)::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
  )
  SELECT g.dia::date,
         COALESCE(SUM(vr.precio_cobrado), 0)::numeric,
         COUNT(vr.dia)::int
  FROM generate_series(p_desde::timestamp, p_hasta::timestamp, interval '1 day') AS g(dia)
  LEFT JOIN ventas_rango vr ON vr.dia = g.dia::date
  GROUP BY g.dia
  ORDER BY g.dia;
$$;
GRANT EXECUTE ON FUNCTION dashboard_ventas_por_dia(DATE, DATE) TO authenticated;
```

- **Una fila por día del rango**, incluso sin ventas (`total = 0`, `cantidad = 0`), por el `generate_series` + `LEFT JOIN`.
- **Total = `precio_cobrado`** (lo realmente cobrado, docs/23), excluyendo `estado = 'anulada'`.
- **`SECURITY INVOKER`**: respeta la RLS de `ventas` (policy `ventas_todos`), no abre nada que el cliente no pudiera leer directo.
- El filtro es un rango de `timestamptz` sobre `created_at`, así que usa `idx_ventas_created_at` (sección 4). El día de cada venta se calcula después del filtro.

**Frontend** (`apps/virikyna-gestion/src/pages/Dashboard/queries.ts`): `useVentasPorDia(desde, hasta)` llama a la RPC con TanStack Query (`queryKey: ['dashboard', 'ventas', desde, hasta]`). "Hoy" en el cliente sale de `hoyAR()` (`packages/shared/lib/format.ts`): la fecha en `America/Argentina/Buenos_Aires`, no la del reloj de la PC.

**Tipos TypeScript** (`apps/virikyna-gestion/src/pages/Dashboard/types.ts`):

```typescript
export type VentaDelDia = {
  fecha: string // YYYY-MM-DD, día en hora AR
  total: number
  cantidad: number
}
```

## 17. Stock bajo calculado en el servidor (card "Stock bajo" de Gestión y Local)

`StockBajoCard` (`packages/shared`, usada en el Dashboard de Gestión y en Local Admin y Cajero) traía todos los productos activos con sus `stock_ubicaciones` y filtraba en el navegador. La API de Supabase corta en 1000 filas por defecto, así que con más de 1000 productos activos los que quedaban afuera nunca se evaluaban. Ahora la suma, el filtro y el orden los hace la base. SQL completo en `docs/26_stock_bajo.sql`.

```sql
CREATE OR REPLACE FUNCTION productos_stock_bajo(p_limite INT DEFAULT NULL)
RETURNS TABLE (id UUID, nombre TEXT, stock_total NUMERIC, stock_minimo NUMERIC, total_count INT)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  WITH stock AS (
    SELECT p.id, p.nombre, p.stock_minimo,
           COALESCE(SUM(s.cantidad), 0) AS stock_total
    FROM productos p
    LEFT JOIN stock_ubicaciones s ON s.producto_id = p.id
    WHERE p.estado = 'activo'
    GROUP BY p.id, p.nombre, p.stock_minimo
  )
  SELECT st.id, st.nombre, st.stock_total, st.stock_minimo,
         (COUNT(*) OVER ())::int AS total_count
  FROM stock st
  WHERE st.stock_total <= st.stock_minimo
  ORDER BY st.stock_total - st.stock_minimo, st.nombre
  LIMIT p_limite;
$$;
GRANT EXECUTE ON FUNCTION productos_stock_bajo(INT) TO authenticated;
```

- **Mismo criterio que antes**: stock total = suma de todas las ubicaciones (0 si el producto no tiene filas en `stock_ubicaciones`), solo `estado = 'activo'`, `stock_total <= stock_minimo`, más crítico primero (`stock_total - stock_minimo` ascendente). Se agregó desempate por `nombre` para que el orden sea estable.
- **`total_count`** sale de `COUNT(*) OVER ()`, que se calcula antes del `LIMIT`: es la cantidad total de productos con stock bajo, la misma en todas las filas. La card la usa para el título ("N productos") y para el "+N más". Si no hay ninguno, la RPC no devuelve filas (total 0).
- **`p_limite` NULL** = sin límite.
- **`SECURITY INVOKER`**: respeta la RLS de `productos` y `stock_ubicaciones`.

**Frontend** (`packages/shared/src/components/StockBajoCard.tsx`): `useQuery` con `queryKey: ['stock-bajo', maxItems]` y `staleTime` de 60 s; `maxItems` se manda como `p_limite`. Las apps que usan la card (Gestión y Local) tienen `QueryClientProvider` en su `main.tsx`.

## 18. Aperturas de caja con diferencia: marcar como revisada (Dashboard de Gestión)

La alerta del Dashboard mostraba las 5 aperturas con diferencia más recientes, sin estado: una diferencia vieja seguía apareciendo hasta que la tapaban 5 nuevas, y una nueva podía quedar escondida detrás de 5 viejas. Ahora cada apertura guarda quién y cuándo la revisó, y la alerta muestra **todas** las pendientes hasta que la dueña las marca. SQL completo en `docs/27_aperturas_revisadas.sql` (tabla original en `docs/21_apertura_caja.sql`).

```sql
ALTER TABLE aperturas_caja ADD COLUMN IF NOT EXISTS revisada_por UUID REFERENCES perfiles(id);
ALTER TABLE aperturas_caja ADD COLUMN IF NOT EXISTS revisada_at TIMESTAMPTZ;
```

- **Sin policy de UPDATE nueva**: igual que en docs/21, la tabla solo se escribe por RPC `SECURITY DEFINER`.
- **`marcar_apertura_revisada(p_apertura_id UUID) RETURNS VOID`** — `SECURITY DEFINER`, exclusivo Admin (valida `rol = 'admin' AND activo` como `validar_cierre_z`). Falla si la apertura no existe, si no tiene diferencia o si ya está revisada (con `FOR UPDATE`, así dos admins a la vez no la marcan dos veces). Solo completa `revisada_por = auth.uid()` y `revisada_at = now()`; el registro no se borra. El `UPDATE` pasa por `trg_auditoria_aperturas_caja`, así que queda en auditoría.
- **`aperturas_con_diferencia_pendientes()`** → `(id, monto_esperado, monto_real, diferencia, usuario_id, usuario_nombre, abierta_at)` — `SECURITY INVOKER` (RLS `aperturas_ver_todos`). Filtra `diferencia <> 0 AND revisada_at IS NULL`, ordena por `abierta_at DESC`, sin límite ni filtro de período. El nombre sale de un `LEFT JOIN` con `perfiles_publico`: `LEFT` porque esa vista solo lista usuarios activos, y la apertura de un cajero ya desactivado tiene que seguir apareciendo (con `usuario_nombre` null).

**Frontend** (`apps/virikyna-gestion/src/pages/Dashboard/AperturasAlerta.tsx`): `useQuery` con `queryKey: ['aperturas-pendientes']` (una sola llamada, sin la consulta aparte a `perfiles_publico`); botón "Marcar revisada" por alerta, visible solo para `rol = 'admin'`; `useMutation` que invalida `['aperturas-pendientes']`, así la alerta revisada desaparece sin recargar. Si la consulta falla se muestra el error en vez de ocultar la alerta.

**Tipos TypeScript** (`packages/shared/types/database.ts`, `AperturaCaja`): se agregan `revisada_por: string | null` y `revisada_at: string | null`.

## 19. Día de caja en hora argentina (la base está en UTC)

**Regla general:** el "día" de negocio es siempre el día en hora argentina (`America/Argentina/Buenos_Aires`) — ni el UTC de la base ni la zona de la PC. La base de Supabase corre en **UTC** (`SHOW timezone` → `UTC`, confirmado): dentro de una función, `current_date` y `created_at::date` dan el día UTC, y entre las 21:00 y las 00:00 hora AR eso ya es "mañana". SQL completo en `docs/28_zona_horaria_caja.sql`.

**Qué pasaba:** un Cierre Z a las 22:00 AR quedaba con `turno_fecha` del día siguiente y, peor, sumaba solo las ventas y egresos de después de las 21:00, ningún retiro del día (Local guarda `retiros_caja.fecha` con el día AR, el cierre buscaba el día UTC) y solo las devoluciones de después de las 21:00 — con eso, `efectivo_esperado` y la diferencia salían mal.

```sql
ALTER FUNCTION cerrar_caja(tipo_cierre, NUMERIC)
  SET timezone = 'America/Argentina/Buenos_Aires';
ALTER FUNCTION crear_devolucion(UUID, motivo_devolucion, TEXT, TEXT, JSONB, JSONB, forma_pago_venta, JSONB)
  SET timezone = 'America/Argentina/Buenos_Aires';

ALTER TABLE devoluciones ALTER COLUMN fecha SET DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
ALTER TABLE retiros_caja ALTER COLUMN fecha SET DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
ALTER TABLE egresos      ALTER COLUMN fecha SET DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
```

- **`SET timezone` en la función** (no en toda la base): dentro de `cerrar_caja` y `crear_devolucion`, `current_date` y `::date` pasan a ser hora AR sin tocar sus cuerpos (versión vigente: docs/24). El resto de la base y la API siguen en UTC.
- **⚠ Al redefinir una de estas funciones** con `CREATE OR REPLACE`, la nueva versión tiene que llevar `SET timezone = 'America/Argentina/Buenos_Aires'` junto al `SET search_path`: el `CREATE OR REPLACE` borra los `SET` anteriores. La verificación 1 de docs/28 lo detecta.
- **DEFAULT de `fecha`** en `devoluciones`, `retiros_caja` y `egresos`: día AR explícito, para cualquier insert que no mande la fecha (p. ej. `registrar_pago_proveedor` con `egresos.fecha`).
- `registrar_retiro_caja` y `registrar_egreso_general` conservan `p_fecha DEFAULT CURRENT_DATE` (default de parámetro, se evalúa en UTC), pero las apps siempre mandan `p_fecha` calculada en hora AR.
- Funciones nuevas con fechas: usar `AT TIME ZONE 'America/Argentina/Buenos_Aires'` explícito (como `dashboard_ventas_por_dia`, sección 16) o `SET timezone`.

**Frontend** (`packages/shared/lib/format.ts`):

- `fechaISO()`, `fechaHoyISO()` y `fechaLocalDeISO()` calculan en hora AR (antes usaban la zona de la PC). Son alias de `hoyAR()`; el nombre se mantiene para no tocar todos los usos.
- `rangoTimestampsAR(desdeDia, hastaDia)` → `{ desde: 'YYYY-MM-DDT00:00:00-03:00', hasta: 'YYYY-MM-DDT23:59:59.999-03:00' }`: para filtrar columnas `timestamptz` por días AR completos. Nunca armar `${dia}T23:59:59` sin zona — la base lo lee en UTC (= 20:59:59 AR). Usado en: Cierre de Caja de Local (egresos del turno), Ventas del día (`VentasDelDiaTab`), Dashboard de Local, Facturación (Local y Gestión) e Historial (Gestión).

## 20. Precio de venta redondeado a la centena + costo desde la factura de compra

SQL completo en `docs/29_redondeo_y_costo_factura.sql` (aplicado). Requiere PostgreSQL 17 (`ALTER COLUMN … SET EXPRESSION`).

**Precio de venta redondeado.** `productos` tiene ahora dos columnas generadas:

```sql
precio_calculado NUMERIC(12,2) GENERATED ALWAYS AS (
  ROUND(costo * (1 + margen_1/100.0) * (1 + margen_2/100.0) * (1 + iva_porcentaje/100.0), 2)
) STORED,
precio_venta NUMERIC(12,2) GENERATED ALWAYS AS (   -- vía ALTER COLUMN … SET EXPRESSION
  ROUND(costo * (1 + margen_1/100.0) * (1 + margen_2/100.0) * (1 + iva_porcentaje/100.0), -2)
) STORED,
```

- `precio_calculado` es el precio exacto de la fórmula (lo que antes era `precio_venta`). Sirve para ver cuánto se redondeó.
- `precio_venta` es lo que se cobra. **⚠ El redondeo a la centena de esta sección fue reemplazado por el redondeo escalonado de la sección 21 (docs/30).**
- Las dos son de solo lectura. `revertir_edicion` (docs/10) excluye ahora `precio_calculado` además de `precio_venta` de lo que restaura: si no, revertir una edición de producto falla con "column can only be updated to DEFAULT".

**Costo desde la factura de compra.** Reemplaza la versión de `cargar_factura_compra` de la sección 13. ⚠ La vigente es la de la sección 23 (docs/33): este mismo cuerpo + `p_copiada_de_id`. Por cada producto vinculado en la factura:

- `productos.costo` = `precio_unitario_sin_iva` del ítem: precio de lista, antes del `descuento_porcentaje` de la línea (es el mismo valor con el que la pantalla precarga el ítem la próxima vez). `precio_venta` y `precio_calculado` se recalculan solos.
- Aplica a todo tipo de comprobante **salvo `nota_credito` y `nota_debito`**. `presupuesto` se agregó al enum vivo en docs/31 (sección 22) y actualiza costo como cualquier otro tipo.
- Producto repetido en la misma factura: gana la **última línea**.
- Ítem con precio 0 (bonificación, sin cargo): no pisa el costo.
- La regla de proveedor y márgenes de la sección 13 sigue igual (también en NC/ND).
- Proveedor, márgenes y costo se escriben en **un solo `UPDATE` por producto** → una sola fila `'edicion'` en `auditoria` (trigger `trg_auditoria_productos`) con costo, márgenes y `precio_venta` antes/después, visible en Historial y en la pestaña Historial de precio. Si no cambia nada, no hay `UPDATE` ni fila. Se puede deshacer con "Revertir" (`revertir_edicion`).
- Stock e ítems: sin cambios.

**Lo que no cambia el costo:**

- `editar_factura_compra` solo toca campos descriptivos. Si se cambia el tipo de una factura ya cargada (p. ej. a nota de crédito), el costo que se cargó queda igual.
- `anular_factura_compra` revierte el stock pero **no el costo**: el producto se queda con el precio de la factura anulada. Para volver atrás: "Revertir" en Historial sobre esa edición, o corregir el costo a mano.
- `actualizar_precios_masivo` sigue aplicando el % sobre `costo` (sin cambios).
- `crear_devolucion` solo lee `precio_venta` (precio de los productos nuevos de un cambio).

**Frontend** (`packages/shared/lib/precios.ts`, reemplaza a `calcularPrecioVenta` de `format.ts`):

- `calcularPrecio({ costo, margen1, margen2, iva })` → `{ calculado, venta, ajuste }`: misma fórmula y mismo redondeo que las dos columnas, con enteros (`BigInt`) en vez de punto flotante para que un ,5 redondee igual que `NUMERIC`. Lo usan los 3 formularios de producto (con el `iva_porcentaje` del producto) y muestran "Calculado → redondeado (ajuste)" cuando hay ajuste.
- `cambiosPrecioFactura(...)`: espejo de las reglas de `cargar_factura_compra` para avisar, por ítem, "Actualiza precio de venta: $A → $B" antes de guardar la factura.
- `costoConPorcentaje(...)` + `useActualizarPrecios` (hook compartido por el modal de escritorio y el sheet de Inventario): vista previa por producto antes de aplicar `actualizar_precios_masivo`.
- Tests: `npm test` (redondeo, entradas de formulario, reglas de factura). Paridad contra la base real: `npm run paridad-precios` (compara cada producto con sus columnas generadas y corre la actualización masiva con varios % en un bloque que se deshace solo).

## 21. Redondeo escalonado del precio de venta

Reemplaza el redondeo a la centena de la sección 20. SQL completo en `docs/30_redondeo_escalonado.sql`. `precio_calculado` no cambia.

**Regla** (base = `precio_calculado`, o sea la fórmula cruda con `ROUND(…, 2)`):

| Base | Redondeo | Ejemplos |
|---|---|---|
| `< 500` | Centena más cercana, la mitad sube | 49 → 0, 50 → 100, 149 → 100, 150 → 200, 449,99 → 400, 450 → 500, 499 → 500 |
| `500 ≤ base < 10000` | Múltiplo de 500. `resto = base mod 500`: `resto ≤ 200` baja, `resto > 200` sube | 500 → 500, 700 → 500, 700,01 → 1000, 6100 → 6000, 6200 → 6000, 6200,01 → 6500, 6300 → 6500, 6700 → 6500, 6700,01 → 7000, 6800 → 7000, 9700 → 9500, 9750 → 10000, 9999,99 → 10000 |
| `≥ 10000` | Múltiplo de 1000 más cercano, 500 sube | 10000 → 10000, 10400 → 10000, 11200 → 11000, 11499,99 → 11000, 11500 → 12000, 11680 → 12000 |
| `0` | — | 0 → 0 |

```sql
CREATE OR REPLACE FUNCTION redondear_precio_venta(p_precio NUMERIC) RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
DECLARE
  v_base NUMERIC := ROUND(p_precio, 2);  -- = precio_calculado
  v_resto NUMERIC;
BEGIN
  IF v_base < 500 THEN
    RETURN ROUND(v_base, -2);
  ELSIF v_base < 10000 THEN
    v_resto := mod(v_base, 500);
    RETURN CASE WHEN v_resto <= 200 THEN v_base - v_resto ELSE v_base - v_resto + 500 END;
  ELSE
    RETURN ROUND(v_base, -3);
  END IF;
END;
$$;

ALTER TABLE productos ALTER COLUMN precio_venta SET EXPRESSION AS (
  redondear_precio_venta(costo * (1 + margen_1/100.0) * (1 + margen_2/100.0) * (1 + iva_porcentaje/100.0))
);
```

⚠ La expresión vigente de `precio_venta` es la de la sección 24 (docs/34): `COALESCE(precio_manual, <esta>)`. Si se cambia `redondear_precio_venta`, el `SET EXPRESSION` a re-correr es ese.

- **La base es `precio_calculado`**: la función hace `ROUND(x, 2)` antes de aplicar la regla. Con eso desaparece el caso raro de la sección 20 (`precio_calculado` 2150,00 con `precio_venta` 2100).
- **`IMMUTABLE`** es obligatorio para usarla en una columna generada.
- **⚠ Si se cambia la función** (`CREATE OR REPLACE`), las filas guardadas **no** se recalculan solas: `precio_venta` es `STORED` y solo se recalcula al escribir la fila. Hay que volver a correr el `ALTER TABLE … SET EXPRESSION` de arriba, que reescribe la tabla y recalcula todo.
- La función no se puede borrar mientras `precio_venta` dependa de ella.
- El recálculo al aplicar no dispara triggers de fila: no genera filas de auditoría.
- El ajuste (`precio_venta − precio_calculado`) ahora puede llegar a ±$500 (antes ±$50). Al momento de diseñarlo, con los 73 productos que había: 57 cambiaban de precio (36 suben, 21 bajan).
- Sin cambios: `costo`, márgenes, IVA, `cargar_factura_compra`, `actualizar_precios_masivo` y ventas (que leen `precio_venta` ya redondeado).

**Frontend** (`packages/shared/lib/precios.ts`): `redondearPrecioVenta(precio)` es el espejo de la función SQL, en centavos enteros (`BigInt`). Es la única implementación de la regla y la usa `calcularPrecio()` (formularios de producto, aviso de factura de compra, vista previa de Actualizar precios). Los 29 casos de la tabla están como test en SQL (bloque 3 de docs/30) y en TS (`packages/shared/tests/precios.test.ts`). Paridad contra la base: `npm run paridad-precios`.

**Orden de despliegue:** primero el SQL, después el frontend. Si el frontend nuevo corre contra la base vieja, los avisos de factura y Actualizar precios muestran el precio "antes" con la regla vieja y el "después" con la nueva.

## 22. Cuenta corriente de proveedores: imputaciones, notas de crédito y origen del pago

SQL completo, verificaciones y tests en `docs/31_cuenta_corriente_proveedor.sql`. Las definiciones que reemplaza se tomaron de la base real (`pg_get_functiondef`), no de este documento.

**Qué estaba mal:**

- Un pago se aplicaba a una sola factura o a ninguna, sin validar monto, proveedor ni anulación.
- Las notas de crédito **sumaban** deuda: `proveedores_saldo` sumaba `total` de todo comprobante, y `facturas_compra_saldo` las mostraba como pendientes de pago.
- Todo pago quedaba con `origen='turno'`, y `cerrar_caja` sumaba **todos** los egresos del día. Un pago en efectivo desde Gestión, o un sueldo cargado en Egresos de Gestión, bajaba el efectivo esperado del Cierre de Caja de Local.
- `egresos` no sabía qué pago lo había generado: la reversión ponía `origen='turno'` fijo.

**Tablas:**

- `tipo_comprobante_compra` + `'presupuesto'`: se comporta igual que remito (suma deuda, actualiza costo, se paga). Ninguna función tuvo que cambiar para eso.
- `pagos_proveedor` + `fecha DATE NOT NULL` (default día AR; backfill desde `created_at`) + `nota TEXT`. **`factura_compra_id` queda deprecated**: solo se completa cuando todo el pago cancela una única factura, para que las pantallas actuales sigan mostrando el pago en el detalle. No usarlo para saldos.
- `egresos` + `pago_proveedor_id` (FK): qué pago generó el egreso. Backfill 1:1 por `created_at` + monto + forma + usuario (pago y egreso se insertan en la misma transacción). Índice único parcial: un egreso original por pago.
- **`pagos_proveedor_aplicaciones`** — una fila = "este monto cancela este comprobante, y sale de X":

| Columna | |
|---|---|
| `factura_compra_id` | comprobante que se cancela (NOT NULL) |
| `monto` | `> 0` |
| `pago_proveedor_id` / `nota_credito_id` | la fuente: plata de un pago o crédito de una NC. **Exactamente una** (CHECK) |
| `operacion_id` | el `pagos_proveedor` de la operación que creó la fila. Para la fuente pago es igual a `pago_proveedor_id`; para una NC, el pago en el que se usó. Es lo que se revierte junto |
| `revertida_at` / `revertida_por` | NULL = vigente. Nunca se borra ni se pone un monto negativo |

  RLS igual a `pagos_proveedor` (cualquier perfil activo). Auditoría por trigger (`alta` al aplicar, `edicion` al marcar revertida). Los pagos existentes con `factura_compra_id` se migran a una aplicación cada uno.

**Vistas** (mismas columnas, las nuevas al final):

- `facturas_compra_saldo`:
  - `total_aplicado`: en un comprobante, pagos + NC aplicados; en una NC, el crédito ya usado.
  - `saldo_pendiente`: `total − total_aplicado`. **0 en NC y en anuladas**.
  - `credito_disponible`: solo NC no anuladas, `total − total_aplicado`.
  - `estado` calculado: `anulada | pendiente | parcial | pagada`. En una NC, `pendiente` = sin usar y `pagada` = agotada.
  - `total_pagado` se mantiene (= `total_aplicado`).
- `proveedores_saldo`: la NC resta (`-total`), el resto de los tipos suma.

Identidad (test 7 de docs/31): `saldo_actual = saldo_inicial + Σ saldo_pendiente − Σ credito_disponible − pagos sin aplicar ("a cuenta")`.

**RPC `registrar_pago_proveedor_v2`** `(p_proveedor_id, p_monto, p_forma_pago, p_factura_ids[], p_nota_credito_ids[], p_origen, p_cierre_caja_id, p_fecha, p_nota, cheque…) → JSONB`

1. Valida: comprobantes del proveedor, no anulados, las facturas no son NC y las NC sí lo son. `origen='general'` solo admin (mismo criterio que `registrar_egreso_general`). Bloquea la fila del proveedor (`FOR UPDATE`): dos pagos simultáneos al mismo proveedor no pueden sobrepagar.
2. Aplica primero el crédito de las NC a las facturas elegidas (o a todas las pendientes si no hay selección), más viejas primero (`fecha_comprobante`).
3. Reparte `p_monto` en el mismo orden. **Con selección**: error si `p_monto` supera el saldo que queda después de las NC. **Sin selección**: el excedente queda a cuenta.
4. `p_monto = 0` solo vale si se aplican NC: crea la fila en `pagos_proveedor` (para Historial y reversión), pero no egreso ni movimiento.
5. Un `pagos_proveedor`, un `egresos` con el origen recibido y `pago_proveedor_id`, y un `movimientos_cuenta` (solo efectivo/transferencia, vía `cuenta_forma_pago`).
6. Devuelve `{pago_id, monto, aplicado_pago, aplicado_nota_credito, a_cuenta, aplicaciones[]}`.

**`registrar_pago_proveedor`** (las dos sobrecargas vivas, la de 9 y la vieja de 6 parámetros) delega en v2, con la misma firma y el mismo retorno. Cambios de comportamiento: con factura, error si está anulada, si es de otro proveedor, si es NC o si el monto supera su saldo; **sin factura, ahora se aplica a las pendientes más viejas** (antes quedaba sin aplicar).

**Otros RPC:**

- `revertir_movimiento` (rama `pagos_proveedor`): marca revertidas todas las aplicaciones de la operación (también las NC usadas), y revierte el egreso con **su origen real**. No permite revertir una reversión.
- `anular_factura_compra`: bloquea si hay aplicaciones vigentes (como comprobante o como NC), en lugar de mirar `pagos_proveedor.factura_compra_id`. Un pago ya revertido ya no bloquea.
- `editar_factura_compra`: no deja convertir un comprobante en NC (ni al revés) si tiene aplicaciones vigentes.
- `cerrar_caja`: suma solo egresos `origen='turno'`. Conserva `SET timezone` (docs/28). La pantalla de Cierre de Caja de Local ya filtraba `turno`.

**Sin cambios:** stock de NC (`cargar_factura_compra` sigue sumando stock en todo tipo de comprobante), clientes, Inventario.

**Pagos a cuenta anteriores a docs/31** (sin factura): siguen restando del saldo del proveedor, pero no quedan aplicados a ningún comprobante. La verificación V6 de docs/31 los lista.

**Orden de despliegue:** parte A sola, después la parte B, después los tests (parte C, con ROLLBACK). Local y Gestión siguen funcionando sin cambios de código. **Pendiente de frontend:** Gestión todavía llama sin `origen`, así que sus pagos siguen entrando como `turno` (y en el cierre de Local) hasta que pase `origen: 'general'`.

## 23. Copiar factura de compra: referencia al origen y aviso de comprobante repetido

SQL completo, verificaciones y tests en `docs/33_copiar_factura_compra.sql`. Antes de escribirlo se comparó `cargar_factura_compra` en la base real (`pg_get_functiondef`) contra docs/29: una sola firma, cuerpo idéntico.

**Para qué:** cargar una factura nueva partiendo de otra ya cargada (mismo proveedor o no). Sirve, por ejemplo, para el flujo de corrección "anular y volver a cargar" (sección 8, `editar_factura_compra` no toca ítems ni montos). La base guarda de qué factura salió la copia.

**Tabla `facturas_compra`** + `copiada_de_id UUID` (null, FK a `facturas_compra(id)`, sin `ON DELETE`: las facturas de compra se anulan, no se borran). Índice parcial `idx_facturas_compra_copiada_de` (`WHERE copiada_de_id IS NOT NULL`). Las facturas cargadas a mano quedan en null.

**RPC `cargar_factura_compra`** — ⚠ la vigente es la de la sección 24 (docs/34): este cuerpo + borrar `precio_manual`. Mismo cuerpo que la sección 20 más un último parámetro `p_copiada_de_id UUID DEFAULT NULL`:

- Si viene, valida que la factura exista (`'La factura que se quiso copiar no existe'`). **No** exige mismo proveedor (al copiar se puede cambiar) y **acepta anuladas**.
- Lo guarda en la fila nueva. Totales, ítems, stock, costo y márgenes, igual que la sección 20.
- Se reemplazó con `DROP` + `CREATE`, no como sobrecarga: con las firmas de 9 y de 10 parámetros vivas a la vez, una llamada de PostgREST con 9 argumentos encaja en las dos y falla con PGRST203. Con una sola firma y default, las llamadas actuales de las tres apps siguen andando sin cambios.

**Vista `facturas_compra_saldo`** + `copiada_de_id` al final (mismo cuerpo que la sección 22).

**`existe_comprobante_compra(p_proveedor_id, p_tipo, p_letra, p_punto_venta, p_numero) → SETOF (id, fecha_comprobante, total, anulada)`** — `LANGUAGE sql STABLE SECURITY INVOKER`. Sirve para que la UI avise "este comprobante ya está cargado"; **no bloquea** (sigue sin haber UNIQUE sobre el comprobante).

- Sin número (null o en blanco): no devuelve nada.
- Mismo proveedor y tipo. Letra exacta, también con null (sin letra ≠ letra A).
- Punto de venta y número sin espacios ni ceros a la izquierda: `0001-00012345` = `1-12345`. Punto de venta vacío = null.
- Incluye anuladas (con `anulada = true`), ordenadas de la más reciente a la más vieja.

**Auditoría:** sin cambios. `trg_auditoria_facturas_compra` guarda `to_jsonb(NEW)`, así que la fila `'alta'` de cada factura ya trae `copiada_de_id` (null si no es copia). Los ítems siguen sin auditoría propia.

**Tipos** (`packages/shared/types/database.ts`): `FacturaCompra.copiada_de_id` (y por herencia `FacturaCompraSaldo`), `ComprobanteCompraExistente`.

**Frontend** (`packages/shared`): `cargarFacturaCompra` manda `p_copiada_de_id` solo cuando hay copia (una carga normal sigue con los 9 parámetros). `obtenerFacturaParaCopiar` + `facturaACopia` arman la precarga, `errorCabeceraFacturaCompra` exige número y fecha en una copia, y `problemasItemsFacturaCompra` bloquea un ítem copiado con producto inactivo sin confirmar. Hooks sin dibujo en `lib/useCopiaFacturaCompra.ts`: `useComprobanteDuplicado` (llama a `existe_comprobante_compra` al salir de Número), `useCopiaFacturaCompra` (carga + confirmación de reemplazo) y `useSelectorFacturaCopia` (`useFacturasRecientes`, sin react-query para que sirva en Inventario). Los usan Local y Gestión (modal + `SelectorFacturaCopiaModal`) e Inventario (`CargarFacturaPage` + `SelectorFacturaCopiaSheet` en un `BottomSheet`); cada app solo pone el dibujo.

## 24. Carga inicial de inventario: precio manual, modo carga inicial y borradores

SQL completo, verificaciones y tests en `docs/34_carga_inicial.sql`. Las definiciones que reemplaza (`cargar_factura_compra`, `actualizar_precios_masivo`, expresiones de `precio_venta` y `precio_calculado`) se tomaron de la base real (`pg_get_functiondef`, `pg_attribute`) el 2026-10-08. **Orden:** la PARTE 0 (enum) sola y antes que la A: un valor de enum nuevo no se puede usar en la misma transacción que lo crea.

**Para qué:** cargar el inventario del local de una vez, desde varios dispositivos a la vez (Local, Inventario y Gestión): código, nombre, marca, descripción, precio de venta y cantidad, **sin proveedor ni costo**, siempre en la ubicación `local`. Al cerrar la etapa, solo un admin puede seguir usándola (la pantalla queda en Gestión).

**Enum:** `tipo_movimiento_stock` + `'inicial'`.

**`productos`:**

- `costo` pasa a **nullable, sin default**. null = sin costo.
- `precio_manual NUMERIC(12,2)` (null; CHECK `> 0`): precio cargado a mano. **Exacto, sin redondeo.**
- CHECK `productos_costo_o_precio_manual`: `costo IS NOT NULL OR precio_manual IS NOT NULL`. Así `precio_venta` nunca queda null.
- `precio_venta` (generada) = `COALESCE(precio_manual, redondear_precio_venta(costo × (1+m1/100) × (1+m2/100) × (1+iva/100)))`. El precio manual gana sobre la fórmula.
- `precio_calculado` no cambia: con costo null ya da null sola.
- `revertir_edicion` no cambia: restaura todas las columnas no generadas, incluidos `precio_manual` y un costo null.

```sql
ALTER TABLE productos ALTER COLUMN precio_venta SET EXPRESSION AS (
  COALESCE(
    precio_manual,
    redondear_precio_venta(costo * (1 + margen_1/100.0) * (1 + margen_2/100.0) * (1 + iva_porcentaje/100.0))
  )
);
```

**`configuracion`** — fila única (`fila_unica BOOLEAN UNIQUE CHECK (fila_unica)`; `id` UUID porque `auditoria.registro_id` es UUID): `carga_inicial_abierta` (default false), `abierta_at`, `abierta_por`, `cerrada_at`, `cerrada_por`, `updated_at`. RLS: SELECT para perfiles activos, **sin policies de escritura**: se cambia solo con `abrir_carga_inicial()` / `cerrar_carga_inicial()` (admin). Es la primera tabla de configuración global; lo que se agregue después va como columnas acá.

**Código interno EAN-13:** `codigo_interno_seq` (1 … 9.999.999.999) + `generar_codigo_interno()` → `'20'` + 10 dígitos de la secuencia + dígito verificador (`ean13_digito_verificador`). El prefijo 20 es de uso interno en GS1: no choca con códigos de fábrica. Salta cualquier valor que ya use un producto (`codigo_barras` o `codigo_interno`) o un borrador. El código generado se guarda en **`codigo_barras`** (se escanea y se imprime como cualquier otro). `codigo_barras_variantes(text)` es el espejo SQL de `variantesCodigoBarras` (12 dígitos ↔ 0 + 12).

**`carga_inicial_items`** — borradores de cada usuario:

| Columna | |
|---|---|
| `usuario_id` | default `auth.uid()`, FK a `perfiles` |
| `codigo_barras` | null = se genera al finalizar. Único por usuario (índice parcial): volver a cargar el mismo código suma la cantidad |
| `nombre` (no vacío), `marca`, `descripcion` | |
| `precio` | `> 0` |
| `cantidad` | `NUMERIC(10,2) > 0` |
| `accion` | `'nuevo' \| 'sumar' \| 'reemplazar'` (CHECK, texto: un enum nuevo pediría otro bloque fuera de transacción) |
| `producto_id` | el producto existente si el código ya estaba (`ON DELETE SET NULL`) |

RLS: cada usuario ve y edita solo sus filas. Escribir directo no saltea el control del modo: los borradores solo se aplican con `carga_inicial_finalizar`. Índices por usuario y por código.

**RPCs** (todas `SECURITY DEFINER`). `carga_inicial_verificar_acceso()`: perfil activo y, salvo admin, carga abierta. Si no: `'La carga inicial está cerrada. Solo un administrador puede usarla.'`

| RPC | Qué hace |
|---|---|
| `carga_inicial_buscar_codigo(p_codigo) → JSONB` | `{codigo, producto, mi_borrador, borradores_otros[]}`. `producto`: nombre, marca, descripción, `precio_venta`, `precio_manual`, `tiene_costo`, `stock_local`. `borradores_otros`: usuario, nombre, precio, cantidad, acción. Busca con variantes del código y también por `codigo_interno` |
| `carga_inicial_guardar_item(p_codigo_barras, p_nombre, p_marca, p_descripcion, p_precio, p_cantidad, p_accion = 'nuevo', p_id = null) → carga_inicial_items` | Sin `p_id`: alta, o suma la cantidad si el código ya está en mis borradores (el resto se pisa con lo nuevo). Con `p_id`: edita ese borrador. Valida: `nuevo` con código existente → error ("elegí sumar o reemplazar"); `sumar`/`reemplazar` sin producto → error; `reemplazar` con otro precio sobre un producto **con costo** → `'Precio calculado por costo…'` |
| `carga_inicial_eliminar_item(p_id)` | Borra un borrador propio |
| `carga_inicial_finalizar() → JSONB` | Aplica **todos mis borradores en una transacción** (abajo) y los borra |
| `carga_inicial_editar_producto(p_producto_id, p_nombre, p_marca, p_descripcion, p_precio, p_cantidad_local) → JSONB` | Vista de inventario total. `p_precio` va a `precio_manual` solo si el producto no tiene costo; con costo, un precio distinto del actual → `'Precio calculado por costo…'` (mandar el mismo precio no es error). `p_cantidad_local` es el **valor absoluto** del stock local: registra un movimiento `'inicial'` por la diferencia (5 → 3 = −2). null en precio o cantidad = no tocar. Sin cambios en los datos, no hay `UPDATE` (ni fila de auditoría) |
| `carga_inicial_resumen() → JSONB` | `{abierta, abierta_at, cerrada_at, productos, unidades, borradores, unidades_borradores, por_usuario[]}`. Lo aplicado sale de `movimientos_stock` tipo `'inicial'` (suma neta); lo pendiente, de los borradores de todos |
| `abrir_carga_inicial() → configuracion` | Solo admin. Error si ya está abierta |
| `cerrar_carga_inicial() → JSONB` | Solo admin. Error si ya está cerrada. **No borra borradores**: devuelve `borradores_pendientes` y `usuarios_con_borradores` para avisar (los de cajeros no se pueden aplicar hasta reabrir) |

**`carga_inicial_finalizar`**, por cada borrador (en orden de carga):

1. Producto: el `producto_id` del borrador si sigue existiendo, si no el que tenga ese código ahora.
2. **Sin producto → alta:** `estado 'activo'`, `costo` null, `precio_manual` = precio, sin proveedor, márgenes 0, IVA 21. Código generado si el borrador no tenía. `INSERT … ON CONFLICT (codigo_barras) DO NOTHING`: si otro usuario dio de alta el mismo código en el medio (el `ON CONFLICT` espera a que su transacción confirme), se toma ese producto y **se suma** (`fusionados`).
3. **`reemplazar`:** pisa nombre, marca, descripción y `precio_manual` (este último solo si no tiene costo; si no, cuenta en `precios_no_aplicados`).
4. **`sumar`**, o `nuevo` cuyo código apareció después: solo stock.
5. Stock: movimiento `'inicial'` (motivo `'Carga inicial'`, `referencia_id` = id del borrador) + `stock_ubicaciones` en `'local'` con `ON CONFLICT … cantidad + x`. Dos usuarios sumando el mismo producto a la vez no se pisan.

Devuelve `{items, productos_creados, productos_reemplazados, stock_sumado, fusionados, precios_no_aplicados, unidades, codigos_generados[{producto_id, nombre, codigo}]}` (para imprimir etiquetas).

**`cargar_factura_compra`** (versión vigente; misma firma que la sección 23): si la factura **le pone costo** a un producto (no NC/ND, precio > 0), además de costo/proveedor/márgenes pone **`precio_manual = null`**: desde ahí el precio sale de la fórmula. Eso pasa aunque el costo sea el mismo que ya tenía. Un producto sin proveedor recibe el de la factura y sus márgenes default (`null IS DISTINCT FROM proveedor` → hereda, como en la sección 13; test T3). Una NC/ND no toca `precio_manual`.

**`actualizar_precios_masivo`** (versión vigente; misma firma):

- Con `precio_manual`: `precio_manual = redondear_precio_venta(precio_manual × (1 + p/100))` — redondeo escalonado (6300 + 2% = 6426 → 6500). Si el redondeo da 0 (precio nuevo menor a $50) queda el valor exacto, para no violar el CHECK.
- Sin `precio_manual`: `costo × (1 + p/100)`, igual que antes.
- `p_porcentaje ≤ −100` → error.

**Auditoría:** `trg_auditoria_configuracion` (INSERT/UPDATE) y `trg_auditoria_carga_inicial_items` (INSERT/UPDATE/DELETE) con `fn_auditoria_generica`. Cada guardado de borrador deja una fila; al finalizar, una `eliminacion` por borrador.

**Tests** (PARTE C, `BEGIN … ROLLBACK`, como el primer admin y el primer cajero activos): precio manual 6300 exacto; +2% → 6500; factura con costo borra el manual, aplica la fórmula y hereda proveedor/márgenes (una NC no); cajero con la carga cerrada → error y admin → ok; dos usuarios suman el mismo código; doble alta del mismo código → se fusiona; `reemplazar`; EAN-13 generado válido; editar cantidad 5 → 3 = movimiento −2; resumen, eliminar, cerrar y auditoría. Se corrió todo en seco contra la base real antes de aplicar (con `'ajuste'` en lugar de `'inicial'`, que todavía no existía).

**Tipos** (`packages/shared/types/database.ts`): `Producto.costo: number | null`, `Producto.precio_manual`, `Producto.precio_calculado: number | null`, `TipoMovimientoStock` + `'inicial'`, `Configuracion`, `AccionCargaInicial`, `CargaInicialItem`, `CargaInicialBusqueda`, `CargaInicialFinalizarResultado`, `CargaInicialEditarResultado`, `CargaInicialResumen`, `CerrarCargaInicialResultado`.

### 34b — "Usar mis datos" sobre borradores de otros, resumen con valor, `datos_reset_at`

SQL, verificaciones y tests en `docs/34b_carga_inicial_reemplazar_y_resumen.sql` (después de 34).

- **`configuracion.datos_reset_at TIMESTAMPTZ`** (null): marca del último vaciado de la base. **Lo pone el script de vaciado** (`UPDATE configuracion SET datos_reset_at = now()`); ninguna RPC lo toca. La pantalla de carga inicial guarda en el navegador las filas que todavía no llegaron al servidor junto con el `datos_reset_at` que vio; si después el de la base es posterior, las descarta.
- **`carga_inicial_guardar_item`**: `'reemplazar'` ya no exige producto, solo código. Es el "Usar mis datos" cuando el código está únicamente en borradores de otros usuarios (`producto_id` null). `'sumar'` sin producto → `'No hay ningún producto con ese código para sumar'`; `'reemplazar'` sin código → `'Para reemplazar datos hace falta el código'`.
- **`carga_inicial_finalizar`**: primero resuelve o crea el producto; si no lo acaba de crear, decide por la acción. `'reemplazar'` sin `producto_id`: si el código existe al finalizar (otro usuario finalizó antes, o un alta simultánea ganó el `ON CONFLICT`), reemplaza datos y suma stock; si no existe, lo crea con mis datos. `'nuevo'` en la misma situación sigue sumando solo stock.
- **`carga_inicial_resumen`** + `valor` (unidades netas de movimientos `'inicial'` × `precio_venta` actual), también por usuario, + `abierta_por_nombre` / `cerrada_por_nombre`.

**Frontend** (`packages/shared/lib/cargaInicial.ts` + `src/components/cargaInicial/`): pantalla `CargaInicial` en `/carga-inicial` de las tres apps (Local y Gestión tabla estilo G, Inventario tarjetas). Detalle funcional en docs/04 módulo 5.2.

- Keys de TanStack Query: `['configuracion']` (refresco 15 s), `['carga-inicial','mios',usuarioId]`, `['carga-inicial','total',busqueda]` (infinita de a 50, búsqueda `ilike` en el servidor, refresco 15 s solo con la pestaña activa y la ventana visible), `['carga-inicial','resumen']`. Inventario ahora tiene `QueryClientProvider` (mismos defaults que Local).
- Filas no guardadas: `localStorage` `virikyna:carga-inicial:pendientes:<usuarioId>:v1` = `{marca: datos_reset_at, filas}`.
- Un error `'La carga inicial está cerrada…'` de cualquier RPC relee la configuración y bloquea la pantalla.

### 34c — Guardado idempotente

SQL, verificaciones y tests en `docs/34c_carga_inicial_idempotencia.sql` (después de 34b).

**Problema:** si se perdía la respuesta de un guardado que sí había llegado, el reintento del cliente volvía a sumar la cantidad (alta con un código que ya está en mis borradores).

- **`carga_inicial_operaciones`** (`client_id` UUID PK, `usuario_id`, `operacion` `'guardar_item' | 'editar_producto'`, `item_id` sin FK, `resultado` JSONB, `created_at`). RLS: SELECT propio; se escribe solo desde las RPCs. `carga_inicial_reclamar_operacion(p_client_id, p_operacion)` (sin `EXECUTE` para `anon`/`authenticated`) la reclama con `INSERT … ON CONFLICT DO NOTHING` al principio de la RPC: dos llamadas simultáneas con el mismo id se ordenan por la PK. Si la operación falla, el registro se deshace con ella y el mismo id se puede reintentar.
- **`carga_inicial_guardar_item(p_client_id, …)`** y **`carga_inicial_editar_producto(p_client_id, …)`**: `p_client_id` obligatorio, primer parámetro (`DROP` + `CREATE`: cambió la firma). Operación ya aplicada → no hace nada y devuelve la fila como está ahora (o solo su `id` si ya se finalizó/eliminó) / el resultado guardado de la primera vez. `client_id` de otro usuario o de otra operación → `'Identificador de operación inválido'`.
- **Sin cambios, verificado por test:** editar un borrador (`p_id`) fija los valores, no suma; `carga_inicial_finalizar` dos veces no aplica dos veces (bloquea y borra los borradores en la misma transacción; la segunda devuelve `items = 0`).
- ⚠ Los tests de docs/34 y docs/34b usan las firmas viejas.

**Cliente:** cada fila nueva genera su `clientId` (`crypto.randomUUID`) y lo guarda en `localStorage` con la fila; Reintentar reusa el mismo. Editar un borrador guardado genera uno nuevo; corregir un **alta** que todavía no se confirmó mantiene el suyo (pudo haber llegado). En Inventario total el `clientId` va con la edición: cambia con cada campo y se reusa si se vuelve a guardar sin cambios. Finalizar con `items = 0` muestra "tu carga ya estaba aplicada".

### 34d — Abrir/cerrar con WHERE (pg_safeupdate)

SQL y test en `docs/34d_carga_inicial_safeupdate.sql` (después de 34c). Las conexiones de la API cargan la extensión `safeupdate` (rol `authenticator`: `session_preload_libraries = supautils, safeupdate`), que rechaza todo `UPDATE`/`DELETE` sin `WHERE` aunque la tabla tenga una sola fila. `abrir_carga_inicial` y `cerrar_carga_inicial` hacían `UPDATE configuracion SET …` sin `WHERE`: desde Gestión respondían 400 "UPDATE requires a WHERE clause". Ahora llevan `WHERE fila_unica`. Los tests por SQL Editor no lo detectan (ahí safeupdate no se carga y `LOAD 'safeupdate'` no está permitido). **Regla:** toda escritura en `configuracion` va con `WHERE fila_unica`.

**Cliente:** las mutaciones de la carga inicial usan `networkMode: 'always'`. Con el default (`'online'`), TanStack las pausaba sin conexión y la fila quedaba en "Guardando…" hasta que volviera internet; ahora fallan enseguida y quedan "No guardada" con Reintentar.

### Frontend de costo vacío y precio manual (resuelve los pendientes de 34)

- **`lib/precios.ts`**: `calcularPrecio({ costo, …, precioManual })` replica `COALESCE(precio_manual, fórmula)`: con precio manual devuelve `venta` = el manual exacto, `ajuste` 0 y `manual: true`; con `costo: null` y sin manual, `calculado: null` (un texto vacío de formulario sigue valiendo 0). `precioManualConPorcentaje` es el espejo de la rama manual de `actualizar_precios_masivo`. `cambiosPrecioFactura` sigue la regla de 34: si la factura le pone costo a un producto con precio manual devuelve `{ tipo: 'reemplaza_manual', manual, despues }` → aviso "Precio manual $6.300 → calculado $7.000"; una NC/ND o un precio 0 no lo tocan.
- **Formularios de producto** (Local, Gestión, Inventario): el alta no cambia. Al editar un producto con precio manual se muestra "Precio de venta (manual)" editable ("Se calcula automáticamente con la primera factura de compra") y el costo vacío ("Sin costo"). Guardar sin tocar el costo deja `costo` en null (un costo 0 heredado junto al manual también pasa a null). Cargar un costo muestra el aviso de reemplazo y guarda `precio_manual = null`.
- **Listados**: costo null → "—" (`formatCurrencyOpcional`), y "manual" debajo del precio (ProductosTab de Local y Gestión, tarjetas de Inventario).
- **Factura de compra**: un producto sin costo deja el precio unitario vacío y muestra "Costo actual: —". La copia de factura trae `precio_manual`.
- **Actualizar precios**: la vista previa marca "Precio manual" en esos productos (el % va sobre el precio, sin tocar el costo).
- **Historial de precio**: cuenta también los cambios de `precio_manual`; costo null se muestra "—" (antes `Number(null)` daba $0).
- **Paridad** (`npm run paridad-precios`): incluye `precio_manual` en las columnas y en la actualización masiva. 2026-10-08: 79 productos (3 manuales), 0 diferencias; 395 comparaciones de actualización masiva, 0 diferencias.
- Pendiente: Historial muestra `configuracion` y `carga_inicial_items` con el nombre de tabla crudo.
