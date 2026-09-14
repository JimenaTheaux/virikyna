---
name: tauri-react-desktop
description: Patrones de arquitectura para apps de escritorio con Tauri v2 y React/TypeScript — separación entre capa Rust y frontend, comandos IPC tipados, plugin de actualizaciones automáticas, empaquetado multiplataforma (Windows/Mac/Linux), y consideraciones de seguridad. Usar al estructurar un proyecto Tauri nuevo, al decidir qué lógica va en Rust vs en el frontend, al configurar auto-updates, o al preparar el build de producción para distribución.
---

# Tauri v2 + React — arquitectura de escritorio

## Por qué Tauri sobre Electron, en una frase

Tauri usa el WebView nativo del sistema operativo (no empaqueta Chromium) y un backend en Rust en vez de Node — el resultado son instaladores de un orden de magnitud más chicos, menor uso de RAM, y un modelo de permisos más estricto por defecto. La contrapartida real: para lo que exceda JS/TS puro (acceso a hardware, sistema de archivos, procesos), hay que tocar algo de Rust, aunque sea mínimo.

## Regla de oro: el frontend no confía en sí mismo para nada sensible

Todo lo que sea validación de negocio real, acceso a hardware (impresoras, lectores), o lógica que no debe poder alterarse desde las devtools del WebView, vive en un **comando Rust** (`#[tauri::command]`), no en el JS del frontend. El frontend llama al comando y muestra el resultado — no reimplementa la regla del lado del cliente "porque es más rápido de escribir".

## Comandos tipados de punta a punta

Escribir los comandos de Rust y consumirlos desde TypeScript sin tipos compartidos a mano es una fuente constante de bugs silenciosos (un campo que cambia de nombre en Rust y nadie actualiza el lado JS). Usar un puente con generación de tipos (ej. `tauri-specta`) para que la firma de cada comando exista en un solo lugar y se derive automáticamente el tipo TypeScript correspondiente.

## Un solo modo de desarrollo, un solo modo de producción — pero probar ambos

La app corre en dos contextos muy distintos: `npm run dev` (WebView apuntando a un servidor Vite) y el binario compilado. Cualquier código que asuma "estoy en un navegador normal" (por ejemplo, llamadas directas a `localhost` de un servicio externo, o el manejo de CORS) se comporta distinto entre ambos modos. Probar explícitamente el build de producción, no asumir que "si anduvo en dev, anda en producción".

## Multi-ventana y menú nativo, si aplica

Si el negocio necesita más de una ventana (ej. un panel secundario, o una ventana flotante con atajo global), Tauri v2 lo soporta de forma nativa desde la configuración, sin necesidad de hacks. Los menús nativos (File/Edit/View, o menús de negocio propios) se arman desde JavaScript pero se integran como menú real del sistema operativo — no un menú HTML que simula serlo.

## Actualizaciones automáticas: hay que armarlas, no vienen gratis

A diferencia de una PWA (que se actualiza sola con cada visita), una app Tauri necesita el plugin `updater` configurado explícitamente:
1. Generar un par de claves de firma propio (`tauri signer generate`) — es una firma de integridad de las actualizaciones, no tiene relación con certificados de Apple/Microsoft ni con notarización.
2. Embeber la clave pública en `tauri.conf.json`.
3. En cada release, publicar el instalador firmado junto a un manifest (`latest.json`) accesible por HTTPS (GitHub Releases, un bucket propio, etc.).
4. La app chequea ese manifest (al abrir, o periódicamente), descarga la actualización si hay una versión nueva, valida la firma, y aplica el update — normalmente con un reinicio.

Este mecanismo se arma una vez; después cada release nuevo es solo "publicar el build + actualizar el manifest".

## Firma y notarización por plataforma — dos problemas distintos

No confundir la firma del **updater** de Tauri (integridad de las actualizaciones) con la firma/notarización del **sistema operativo**:
- **Windows**: sin certificado de firma de código, el instalador dispara advertencia de SmartScreen. No bloquea la instalación, solo agrega un paso de "igual quiero instalar esto".
- **macOS**: Gatekeeper sí puede bloquear la ejecución de un binario no firmado/notarizado ("la app está dañada"), no solo advertir. Para distribución en máquinas que uno no controla directamente, notarización con cuenta Apple Developer es la vía sin fricción. Para instalación en máquinas propias/de un cliente conocido, existe el workaround manual de quitar el atributo de cuarentena (`xattr -cr`), viable para desplegar en pocas máquinas controladas, no para distribución pública.

## Seguridad: CSP y permisos explícitos

Tauri v2 usa un sistema de permisos por capacidad (`capabilities`) — cada plugin y cada ventana declara explícitamente a qué puede acceder (sistema de archivos, red, shell, etc.), en vez de dar acceso total por defecto. Configurar el Content-Security-Policy del WebView y revisar qué capacidades tiene habilitadas cada ventana, en particular si la app carga contenido remoto en algún punto.

## Checklist antes de un release

- [ ] Lógica sensible (hardware, validaciones de negocio críticas) vive en comandos Rust, no en el frontend
- [ ] Tipos compartidos entre Rust y TypeScript generados, no escritos a mano en paralelo
- [ ] Build de producción probado en cada sistema operativo objetivo, no solo el modo dev
- [ ] Plugin `updater` configurado con clave de firma propia y manifest publicado
- [ ] Estrategia de firma/notarización definida por plataforma (Windows: certificado opcional; Mac: Apple Developer o workaround manual, según cuántas máquinas y quién las controla)
- [ ] Capabilities y CSP revisados, sin permisos de más por comodidad
