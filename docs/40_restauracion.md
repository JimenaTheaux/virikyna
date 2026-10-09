# 40 — Backup y restauración de Virikyna

Cómo sacar un backup de la base y cómo levantar Virikyna desde cero en un proyecto nuevo de Supabase si el actual se pierde (borrado, corrupción o problema de cuenta). Escrito el 2026-10-08, con la base en Postgres 17.6, región `sa-east-1`, proyecto `ccpinvtleqlsukcqnili`.

> **El repo es público.** Ningún archivo de backup (`data.sql`), certificado, clave ni contraseña va al repo. En el repo vive solo la **estructura**: `supabase/schema/schema.sql` y `roles.sql`.

---

## 1. Sacar un backup

```bash
bash scripts/backup.sh
```

Deja en `~/Backups/virikyna/AAAA-MM-DD/` (si la carpeta ya existe, le agrega la hora):

| Archivo | Qué tiene |
|---|---|
| `roles.sql` | Ajustes de los roles de Supabase (`anon`, `authenticated`…). Sin contraseñas. |
| `schema.sql` | Estructura de `public`: tablas, vistas, funciones, triggers, policies, grants, default privileges, secuencias. |
| `data.sql` | **Todos los datos**: `public` y `auth` (usuarios con hash de contraseña, identidades, sesiones). También los valores de las secuencias (`setval`). **Sensible.** |
| `SHA256SUMS` | Para comprobar que los archivos no se dañaron. |
| `resumen.txt` | Cantidad de tablas, funciones, policies y filas por tabla. Comparar contra el backup anterior. |

**Requisitos:** Supabase CLI logueada y el repo linkeado (`supabase link --project-ref ccpinvtleqlsukcqnili`), más `pg_dump`/`pg_dumpall` 17. No hace falta Docker: el script usa `supabase db dump --dry-run`, que imprime el `pg_dump` con credenciales temporales, y lo corre con los binarios de `~/tools/pgsql17/bin`. Esos binarios salen de la carpeta `pgsql/bin` del zip "PostgreSQL 17 windows-x64-binaries" de EnterpriseDB, no se instalan; la ruta se cambia con `PG_BIN`.

**Después de cada backup:** copiar la carpeta a un lugar **fuera de esta PC** (Drive, pendrive). Un backup que vive solo en la PC de la caja no sirve si esa PC se rompe o se pierde.

**Frecuencia sugerida:** semanal, y siempre antes de correr SQL a mano en producción. Si el proyecto pasa a plan Pro, Supabase hace además backups diarios (Database → Backups). El manual sigue siendo útil porque queda en tus manos.

**Actualizar la estructura versionada** (después de aplicar un `docs/NN_*.sql`):

```bash
SCHEMA_AL_REPO=1 bash scripts/backup.sh
git diff supabase/schema/      # revisar: tiene que ser solo estructura
```

Los avisos `circular foreign-key constraints` del dump de datos son normales: son las columnas `revierte_*_id`, que apuntan a la misma tabla. `data.sql` empieza con `SET session_replication_role = replica`, que desactiva esas verificaciones durante la carga.

---

## 2. Qué NO está en el backup

Todo esto hay que tenerlo guardado por separado (gestor de contraseñas y copia offline) o volver a configurarlo a mano:

| Qué | Dónde vive hoy | Si se pierde |
|---|---|---|
| **Secretos de las Edge Functions**: `ARCA_CUIT`, `ARCA_PUNTO_VENTA`, `ARCA_HOMO_CERT`, `ARCA_HOMO_KEY`, `ARCA_PROD_CERT`, `ARCA_PROD_KEY`, `ARCA_PROD_PUNTO_VENTA` | Supabase → Edge Functions → Secrets. Supabase **no deja volver a leerlos**. | Volver a cargarlos desde los archivos originales. |
| **Certificado y clave privada de ARCA** (producción y homologación) | `Desktop/Theaux soluciones/arca_virikyna/` (`.crt`, `.key`) | Generar CSR y certificado nuevos en ARCA con clave fiscal (≈1 h) y actualizar los secretos. |
| **Clave de firma del updater de Tauri** + su contraseña | `.secrets/` del repo (ignorada por git) y GitHub → Settings → Secrets (no se puede leer) | **No hay más actualizaciones automáticas de Local.** Ver sección 4. |
| **Código de las Edge Functions** | En el repo: `supabase/functions/` | — (está versionado) |
| **Configuración de Auth**: registro público desactivado, largo mínimo de contraseña, URLs, plantillas de mail, expiración de JWT | Supabase → Authentication | Volver a configurarlo (sección 3, paso 6). |
| **API keys y URL del proyecto** | Cambian con el proyecto nuevo | Actualizar Vercel, GitHub y los `.env.local` (paso 7). |
| **Variables de Vercel**: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` (Gestión e Inventario) | Vercel → cada proyecto → Settings → Environment Variables | Se recargan con los valores del proyecto nuevo. |
| **Secretos de GitHub Actions**: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | GitHub → Settings → Secrets and variables → Actions | Los dos de Tauri: ver sección 4. |
| **Archivos de Storage** | Virikyna no usa Storage hoy | — |
| **Contraseña de la base**, plan, backups automáticos, restricciones de red, 2FA de la cuenta | Dashboard de Supabase | Se definen en el proyecto nuevo. |
| **Logs** (API, Auth, Edge Functions) | Dashboard, con retención según plan | Se pierden; no son necesarios para restaurar. |

---

## 3. Restaurar en un proyecto nuevo de Supabase

Tiempo estimado: 1–2 horas. Con la caja cerrada (sin ventas en curso).

### Paso 1 — Verificar el backup
```bash
cd ~/Backups/virikyna/AAAA-MM-DD
sha256sum -c SHA256SUMS        # las tres tienen que dar OK
cat resumen.txt
```

### Paso 2 — Crear el proyecto
1. Supabase → **New project**. Región **South America (São Paulo) `sa-east-1`**, la misma de antes, y Postgres 17.
2. Anotar la **contraseña de la base** en el gestor de contraseñas.
3. **Project Settings → Database → Connection string**: copiar la de **Session pooler** (puerto 5432) con la contraseña.

### Paso 3 — Cargar roles, estructura y datos
Con `psql` 17 (está en `~/tools/pgsql17/bin/psql.exe`):

```bash
export PATH="$HOME/tools/pgsql17/bin:$PATH"
cd ~/Backups/virikyna/AAAA-MM-DD
psql \
  --single-transaction \
  --variable ON_ERROR_STOP=1 \
  --file roles.sql \
  --file schema.sql \
  --command 'SET session_replication_role = replica' \
  --file data.sql \
  --dbname "postgresql://postgres.<ref-nuevo>:<contraseña>@aws-0-sa-east-1.pooler.supabase.com:5432/postgres"
```

Es una sola transacción: si algo falla, no queda nada a medias. Se corrige el problema y se vuelve a correr.

### Paso 4 — Verificar la base
En el SQL Editor del proyecto nuevo:
1. Conteo de filas por tabla, a comparar con `resumen.txt`:
   ```sql
   SELECT c.relname AS tabla,
          (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM public.%I', c.relname), false, true, '')))[1]::text::bigint AS filas
   FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r' ORDER BY 1;
   ```
2. Las consultas de **VERIFICACIÓN** de `docs/38_seguridad_prelanzamiento.sql` y `docs/39_advisor_funciones_internas.sql`: `anon` sin acceso, vistas, policies, numeración.
3. Todas las consultas de `docs/37_chequeos_salud.sql`: tienen que dar 0 filas, salvo las informativas.
4. **Advisors → Security Advisor**: lo esperable está descripto en docs/39.

### Paso 5 — Edge Functions y sus secretos
```bash
cd <repo>
supabase link --project-ref <ref-nuevo>
supabase functions deploy admin-usuarios
supabase functions deploy arca-emitir-factura
```
Secretos: armar un archivo **fuera del repo** (ej. `~/arca.env`) con `ARCA_CUIT`, `ARCA_PUNTO_VENTA`, `ARCA_PROD_PUNTO_VENTA`, y el contenido PEM completo de `ARCA_HOMO_CERT`, `ARCA_HOMO_KEY`, `ARCA_PROD_CERT` y `ARCA_PROD_KEY` (los archivos de `arca_virikyna/`):
```bash
supabase secrets set --env-file ~/arca.env
rm ~/arca.env
supabase secrets list            # tienen que aparecer los 7 ARCA_*
```
`SUPABASE_URL`, `SUPABASE_ANON_KEY` y `SUPABASE_SERVICE_ROLE_KEY` los inyecta Supabase solo.

Si el certificado de ARCA cambió, vaciar la caché de tickets: `DELETE FROM arca_wsaa_tokens WHERE true;`. Si no, los tickets restaurados vencen solos en ≤ 12 h.

### Paso 6 — Auth
**Authentication → Sign In / Providers**:
- Email habilitado, **Allow new users to sign up: desactivado**.
- Confirmación de email: igual que antes (los usuarios los crea el admin con `email_confirm`).

Los usuarios y sus contraseñas vuelven con `data.sql` (`auth.users`). El proyecto nuevo firma los tokens con otra clave, así que **todos tienen que volver a iniciar sesión**.

### Paso 7 — Apuntar las apps al proyecto nuevo
Datos: **Project Settings → API Keys**: URL del proyecto y **Publishable key** (`sb_publishable_…`). Nunca la secret.

1. **Vercel** (Gestión e Inventario) → Settings → Environment Variables: actualizar `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` → **Redeploy** de cada uno.
2. **GitHub** → Settings → Secrets and variables → Actions: actualizar `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY`.
3. **Virikyna Local**: la URL y la key quedan dentro del instalador, así que hay que **publicar una versión nueva**. Se sube la versión en `apps/virikyna-local/package.json`, `src-tauri/tauri.conf.json`, `src-tauri/Cargo.toml` y el `package-lock.json` raíz, se pushea a `main` y se pushea el tag `virikyna-local-vX.Y.Z`, que dispara `.github/workflows/release-virikyna-local.yml`. Las cajas la bajan solas al abrir. El updater depende de GitHub, no de Supabase.
4. En la PC de desarrollo: `apps/*/.env.local` con los valores nuevos.

### Paso 8 — Prueba de punta a punta
Login admin y cajero en las 3 apps, dashboard, inventario, carga inicial y búsqueda. Después, una venta real chica y su anulación desde Gestión: deja rastro en auditoría, y está bien que quede.

### Paso 9 — Cerrar
- Activar backups del proyecto nuevo (plan) y correr `bash scripts/backup.sh` apenas esté andando.
- Si el proyecto viejo sigue existiendo, pausarlo para que nadie escriba ahí por error.
- Actualizar la referencia `ccpinvtleqlsukcqnili` en `scripts/backup.sh` y en los docs que la mencionan.

---

## 4. Clave del updater de Tauri

Está en `.secrets/virikyna-local-updater.key` (+ `updater-key-password.txt`) y como secreto de GitHub. La clave pública va en `apps/virikyna-local/src-tauri/tauri.conf.json` (`plugins.updater.pubkey`). Cada caja instalada **solo acepta updates firmados con esa clave**.

- **Si el secreto de GitHub se borra pero tenés el archivo:** volver a cargar `TAURI_SIGNING_PRIVATE_KEY` (contenido del `.key`) y `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`.
- **Si se pierde la clave privada:** generar un par nuevo (`npx tauri signer generate -w <ruta fuera del repo>`), poner la pubkey nueva en `tauri.conf.json`, cargar los secretos en GitHub, publicar una versión, y **reinstalar Local a mano en cada caja** con el `.exe` de esa versión. Las instaladas no aceptan nada firmado con otra clave.

Por eso la clave y su contraseña tienen que estar en un gestor de contraseñas y en una copia offline, no solo en esta PC.

---

## 5. Restaurar sobre el mismo proyecto (datos dañados, proyecto sano)

Para un error puntual (borraron algo, un SQL a mano salió mal), primero mirar si alcanza con el **Historial** de Gestión (reversiones) o con SQL dirigido. Pisar todos los datos pierde lo que se hizo después del backup.

Si hace falta volver todo atrás:
- **Plan Pro:** Database → Backups → **Restore** del día (o PITR si está contratado).
- **Solo con backup manual:** restaurar en un **proyecto nuevo** (sección 3), verificar, y recién ahí apuntar las apps a ese proyecto. No cargar `data.sql` sobre una base con datos: choca con lo que ya existe.

---

## 6. Simulacro

Una vez, con la base todavía chica: crear un proyecto Free de prueba, hacer los pasos 1–4 con el último backup, comprobar conteos y chequeos, y borrar el proyecto de prueba. Es la única forma de saber que el backup sirve.
