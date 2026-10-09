#!/usr/bin/env bash
# Backup completo de la base de Virikyna (Supabase, proyecto ccpinvtleqlsukcqnili) FUERA del repo.
#
#   bash scripts/backup.sh            → ~/Backups/virikyna/AAAA-MM-DD/   (si ya existe: AAAA-MM-DD_HHMMSS)
#   BACKUP_ROOT=/otra/ruta bash scripts/backup.sh
#
# Genera roles.sql, schema.sql y data.sql (los mismos tres de `supabase db dump`), más
# SHA256SUMS y resumen.txt. data.sql incluye auth.users (hashes de contraseña), tokens de ARCA y
# datos de clientes: NUNCA va al repo (que es público). Guardar una copia fuera de la PC.
#
# Requisitos:
#   - Supabase CLI logueada y el repo linkeado (`supabase link --project-ref ccpinvtleqlsukcqnili`).
#   - pg_dump y pg_dumpall 17 (misma versión mayor que la base). Se buscan en PG_BIN, si no en el PATH, y
#     si no en ~/tools/pgsql17/bin (binarios portables de PostgreSQL 17 para Windows, carpeta pgsql/bin
#     del zip "windows-x64-binaries" de EnterpriseDB). No hace falta Docker.
#
# Cómo funciona: `supabase db dump --dry-run` imprime el script de pg_dump que correría la CLI, con
# credenciales TEMPORALES de un rol de login que la CLI crea (sin pedir la clave de la base). Ese
# script se pasa directo a bash por un pipe: las credenciales no se escriben a disco.
#
# Restaurar: docs/40_restauracion.md.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/Backups/virikyna}"
PG_BIN="${PG_BIN:-}"

# ── pg_dump 17 ───────────────────────────────────────────────────────────────────────────────────
if [ -z "$PG_BIN" ]; then
  if command -v pg_dump >/dev/null 2>&1; then
    PG_BIN="$(dirname "$(command -v pg_dump)")"
  elif [ -x "$HOME/tools/pgsql17/bin/pg_dump.exe" ] || [ -x "$HOME/tools/pgsql17/bin/pg_dump" ]; then
    PG_BIN="$HOME/tools/pgsql17/bin"
  else
    echo "ERROR: no encuentro pg_dump. Definí PG_BIN o instalá PostgreSQL 17 (cliente)." >&2
    exit 1
  fi
fi
export PATH="$PG_BIN:$PATH"
PG_VERSION="$(pg_dump --version | grep -oE '[0-9]+' | head -1)"
if [ "$PG_VERSION" -lt 17 ]; then
  echo "ERROR: pg_dump $PG_VERSION es viejo; la base es Postgres 17." >&2
  exit 1
fi

# ── Carpeta destino (fuera del repo) ─────────────────────────────────────────────────────────────
DEST="$BACKUP_ROOT/$(date +%F)"
[ -e "$DEST" ] && DEST="${DEST}_$(date +%H%M%S)"
case "$(cd "$(dirname "$DEST")" 2>/dev/null && pwd || echo "$DEST")/" in
  "$REPO_DIR"/*) echo "ERROR: el destino $DEST está dentro del repo." >&2; exit 1 ;;
esac
mkdir -p "$DEST"
chmod 700 "$DEST" 2>/dev/null || true

# ── Dumps ────────────────────────────────────────────────────────────────────────────────────────
# $1 = archivo, $2.. = flags de `supabase db dump` (sin flags = schema)
dump() {
  local archivo="$1"; shift
  echo "→ $archivo"
  (cd "$REPO_DIR" && supabase db dump --linked --dry-run "$@" 2>/dev/null) \
    | sed -n '/^#!\/usr\/bin\/env bash/,$p' \
    | sed -E 's/--quote-all-identifier( |$)/--quote-all-identifiers\1/' \
    | bash > "$DEST/$archivo"
  # La CLI abrevia --quote-all-identifiers: getopt de Linux lo acepta, el de los binarios de Windows no.
}

dump roles.sql --role-only
dump schema.sql
dump data.sql --data-only

# ── Verificación ─────────────────────────────────────────────────────────────────────────────────
falla=0
verificar() {  # $1 archivo, $2 patrón que tiene que aparecer, $3 descripción
  if [ ! -s "$DEST/$1" ]; then echo "  ✗ $1 vacío"; falla=1; return; fi
  if ! grep -qE "$2" "$DEST/$1"; then echo "  ✗ $1 no contiene $3"; falla=1; return; fi
  echo "  ✓ $1 ($(du -h "$DEST/$1" | cut -f1))"
}
verificar roles.sql  'CREATE ROLE|ALTER ROLE'                         'roles'
verificar schema.sql 'CREATE TABLE IF NOT EXISTS "public"\."ventas"'  'la tabla ventas'
verificar data.sql   'INSERT INTO "public"\."perfiles"'               'los perfiles'

{
  echo "Backup Virikyna — $(date '+%F %T')"
  echo "Proyecto: ccpinvtleqlsukcqnili · pg_dump $(pg_dump --version | grep -oE '[0-9.]+$')"
  echo
  echo "Tablas en schema.sql:        $(grep -cE '^CREATE TABLE IF NOT EXISTS "public"\.' "$DEST/schema.sql")"
  echo "Funciones en schema.sql:     $(grep -cE '^CREATE OR REPLACE FUNCTION "public"\.' "$DEST/schema.sql")"
  echo "Policies en schema.sql:      $(grep -cE '^CREATE POLICY ' "$DEST/schema.sql")"
  echo
  echo "Filas por tabla en data.sql (INSERT con --column-inserts, filas de VALUES):"
  awk '
    /^INSERT INTO "[a-z_]+"\."[a-z_0-9]+"/ { match($0, /"[a-z_]+"\."[a-z_0-9]+"/); t = substr($0, RSTART, RLENGTH); dentro = 1; next }
    dentro && /^\t\(/ { n[t]++ }
    dentro && /;$/ { dentro = 0 }
    END { for (k in n) printf "  %-55s %d\n", k, n[k] }' "$DEST/data.sql" | sort
} > "$DEST/resumen.txt"

(cd "$DEST" && sha256sum roles.sql schema.sql data.sql > SHA256SUMS)

# Opcional: SCHEMA_AL_REPO=1 copia la estructura (nunca data.sql) a supabase/schema/ para versionarla.
if [ "${SCHEMA_AL_REPO:-0}" = "1" ] && [ "$falla" = "0" ]; then
  mkdir -p "$REPO_DIR/supabase/schema"
  cp "$DEST/schema.sql" "$DEST/roles.sql" "$REPO_DIR/supabase/schema/"
  echo "Estructura copiada a supabase/schema/ (revisar con git diff antes de commitear)."
fi

echo
cat "$DEST/resumen.txt"
echo
echo "Backup en: $DEST"
echo "Copialo fuera de esta PC (Drive, pendrive). data.sql tiene datos sensibles."
exit $falla
