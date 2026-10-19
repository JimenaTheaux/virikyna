# 44 — Backup diario programado y restauración probada

Complementa a `docs/40_restauracion.md`, que explica cómo levantar Virikyna en un proyecto nuevo de Supabase. Este documento cubre dos cosas:
- el **backup automático diario** en la PC de desarrollo;
- la **prueba de restauración** en un Postgres local temporal, hecha el 2026-10-19 con resultado OK.

> El repo es público: acá no va ninguna contraseña ni ningún dato. Los backups y los scripts viven **fuera del repo**, en `C:\Users\Usuario\Desktop\Theaux soluciones\backups\`.

---

## 1. Piezas

| Pieza | Dónde |
|---|---|
| Script de backup | `backups\backup-virikyna.ps1` |
| Script de prueba de restauración | `backups\restaurar-prueba.ps1` |
| Log de ejecuciones | `backups\backup-virikyna.log` (una línea por corrida: `[OK]`, `[ERROR]` o `[INFO]` de rotación) |
| Backups | `backups\virikyna_AAAA-MM-DD_HHmm\` (automáticos) y `backups\virikyna_AAAA-MM-DD_<etiqueta>\` (manuales) |
| Binarios PostgreSQL 17.6 | `C:\Users\Usuario\tools\pgsql17\` (`bin`, `lib`, `share` del zip "windows-x64-binaries" de EnterpriseDB; no se instalan) |
| Tarea programada | Programador de tareas → `\Virikyna\Virikyna - Backup diario` |

Cada carpeta de backup tiene `schema.sql` (estructura de `public`), `data.sql` (datos de `public`, `auth` y `storage`), `roles.sql` (sin contraseñas), `conteos.txt` (filas por tabla) y `tamanos.txt`. **`data.sql` es sensible**: tiene hashes de contraseñas, datos de clientes y tokens de ARCA.

### Credenciales
El script **no necesita guardar la contraseña de la base**. Usa el mismo mecanismo que `scripts/backup.sh`: `supabase db dump --linked --dry-run` entrega credenciales **temporales** de un rol de login creado por la CLI (`cli_login_postgres`, que pasa a `postgres` con `--role`). Se leen en memoria y no se escriben a disco. Requisito: Supabase CLI logueada (`supabase login`) y el repo linkeado.

Solo si la CLI falla, usa como respaldo la variable `SUPABASE_DB_PASSWORD` o `virikyna\.secrets\supabase-db-password.txt`. Ese archivo es opcional y se puede borrar.

### Relación con `scripts/backup.sh` (docs/40)
Los dos sacan los mismos tres archivos. `backup.sh` (bash, manual) deja en `~/Backups/virikyna/` y agrega `SHA256SUMS` y `resumen.txt`. `backup-virikyna.ps1` (PowerShell) es el que corre la tarea programada, con log y retención. Para restaurar sirve cualquiera de los dos.

---

## 2. Backup programado

- **Cuándo:** todos los días a las **23:00**. Si la PC estaba apagada a esa hora, corre apenas se prende ("Iniciar la tarea lo antes posible después de perder un inicio programado").
- **Cómo corre:** como el usuario `Usuario`, **solo con la sesión iniciada** (no guarda la contraseña de Windows), en ventana oculta, con un límite de 1 hora y sin superponerse con otra corrida.
- **Comando:** `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "…\backups\backup-virikyna.ps1"`
- **Retención:** después de cada backup **OK**, conserva las **14** carpetas automáticas más nuevas (`virikyna_AAAA-MM-DD_HHmm`) y borra las anteriores.
  - Las carpetas **con etiqueta** (ej. `virikyna_2026-10-19_post-inventario`) **no se borran nunca**.
  - Si una corrida falla, su carpeta queda como `…_FALLIDO` y se borra pasados 14 días.
  - Nunca se borra una copia buena si la del día falló.
- **Cómo saber si anduvo:** última línea de `backups\backup-virikyna.log`, o en el Programador de tareas, "Resultado de la última ejecución" = `0x0`.

### Pausar, editar, correr a mano o borrar

Desde PowerShell:

```powershell
# Pausar / reanudar
Disable-ScheduledTask -TaskPath '\Virikyna\' -TaskName 'Virikyna - Backup diario'
Enable-ScheduledTask  -TaskPath '\Virikyna\' -TaskName 'Virikyna - Backup diario'

# Correr ahora (sin esperar a las 23:00)
Start-ScheduledTask -TaskPath '\Virikyna\' -TaskName 'Virikyna - Backup diario'

# Cambiar la hora
Set-ScheduledTask -TaskPath '\Virikyna\' -TaskName 'Virikyna - Backup diario' -Trigger (New-ScheduledTaskTrigger -Daily -At '22:00')

# Ver estado, última y próxima ejecución
Get-ScheduledTaskInfo -TaskPath '\Virikyna\' -TaskName 'Virikyna - Backup diario'

# Borrarla
Unregister-ScheduledTask -TaskPath '\Virikyna\' -TaskName 'Virikyna - Backup diario' -Confirm:$false
```

Desde la interfaz: **Programador de tareas** (`taskschd.msc`) → carpeta **Virikyna** → clic derecho sobre la tarea → Deshabilitar / Ejecutar / Propiedades / Eliminar.

Para cambiar la cantidad de copias que se conservan, agregar `-Retener N` al final de los argumentos de la tarea (Propiedades → Acciones).

### Backup manual con nombre (antes de un cambio en producción)
```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\Usuario\Desktop\Theaux soluciones\backups\backup-virikyna.ps1" -Etiqueta pre-docs45
```

### Siempre
Copiar periódicamente algún backup **fuera de esta PC** (Drive, pendrive). La tarea solo protege contra problemas de Supabase, no contra perder la PC.

---

## 3. Prueba de restauración (Postgres local temporal)

Sirve para comprobar que un backup se puede restaurar, **sin tocar producción y sin Docker**. Restaurar de verdad en un proyecto nuevo de Supabase es la sección 3 de `docs/40`.

```powershell
cd "C:\Users\Usuario\Desktop\Theaux soluciones\backups"
powershell -ExecutionPolicy Bypass -File .\restaurar-prueba.ps1 -Backup virikyna_2026-10-19_post-inventario -Mantener
# … inspeccionar con psql -h localhost -p 54329 -U supabase_admin -d postgres …
powershell -ExecutionPolicy Bypass -File .\restaurar-prueba.ps1 -SoloApagar
```

Sin `-Mantener`, apaga y borra la base al terminar.

### Qué hace, en orden
1. **`initdb`** de un clúster nuevo en `%TEMP%\virikyna-restore-test\cluster`, puerto **54329**, escuchando solo en localhost. La collation es ICU `en-US`, igual que producción. El superusuario de arranque se llama **`supabase_admin`**, como en Supabase: `roles.sql` otorga las membresías `GRANTED BY supabase_admin`, y en PG17 solo el superusuario de `initdb` tiene ADMIN implícito sobre todos los roles.
2. **Sustituto mínimo de Supabase** (`00_sustituto_supabase.sql`, generado). El backup no trae la *estructura* de `auth`/`storage`, porque la administra Supabase y en un proyecto nuevo ya existe. Para la prueba se crean:
   - los esquemas `auth`, `storage`, `extensions` y `vault`;
   - las funciones `auth.uid()`, `auth.role()` y `auth.jwt()`;
   - las tablas de `auth`/`storage` con las columnas que trae `data.sql` (todas `text`, salvo `auth.users.id uuid PRIMARY KEY`, que es la FK de `perfiles`);
   - las secuencias de `auth` que `data.sql` reposiciona.
3. **`roles.sql`** → **`schema.sql`** → **`data.sql`**. Los datos van en **una sola transacción** con `session_replication_role = replica`, sin disparar triggers ni FK durante la carga.
4. **Conteos** del restaurado contra `conteos.txt`.
5. Apagar y borrar todo.

En Windows, `pg_ctl` se lanza con `Start-Process` en una ventana aparte. Si se lanza capturando la salida, el servidor hereda los pipes y el comando no termina nunca.

### Resultado de la prueba del 2026-10-19 (backup `virikyna_2026-10-19_post-inventario`)

| Paso | Errores | Detalle |
|---|---:|---|
| Sustituto | 0 | |
| `roles.sql` | 1 | `role "supabase_admin" already exists`: esperable (es el superusuario de arranque) |
| `schema.sql` | 8 | Todos de piezas administradas por Supabase, esperables: extensión `supabase_vault` no disponible (+ su `COMMENT`), 6 event triggers que llaman funciones de `extensions.*` (`pgrst_ddl_watch`, `grant_pg_net_access`…), aviso de `wal_level` en la publicación `supabase_realtime`. **Ningún error en objetos de `public`.** |
| `data.sql` | 0 | Una transacción, sin errores |

**Conteos:** 64 tablas restauradas, **todas iguales** a `conteos.txt`. Las únicas dos que faltan son `auth.schema_migrations` (82) y `storage.migrations` (74): el backup las excluye a propósito, porque son el historial de migraciones interno de Supabase.

**Muestras**, comparadas con producción el mismo día (iguales en todos los casos):

| Qué | Resultado |
|---|---|
| 5 productos al azar: nombre, costo, precio manual, `precio_venta`, stock | Iguales. `precio_venta` es columna generada y se **recalculó** al restaurar. |
| SQUISHI BUTTER MANTECA (con costo, precio por fórmula) | `precio_venta` 24.000, `precio_calculado` 23.760,53, iguales |
| Suma de `precio_venta` de los 2.164 productos | 89.911.115,00 en los dos |
| 20 proveedores (md5 de razón social + CUIT + márgenes) | Iguales |
| Saldo del proveedor de la factura (vista `proveedores_saldo`) | 0,00 en los dos |
| Factura de compra (vista `facturas_compra_saldo`) | cupón, total 237.605,28, IVA 41.237,28, pagada, saldo 0, igual |
| Objetos de `public` | 61 funciones, 25 triggers, 34 policies, 6 vistas, 73 índices, iguales |

**Conclusión:** el backup se restaura completo. Para un desastre real hay que seguir `docs/40` §3 (proyecto nuevo de Supabase). Ahí `auth`, `storage` y las extensiones ya existen, y no hace falta el sustituto.
