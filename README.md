# Virikyna — Paquete de documentación técnica (Fase 1)

## Contenido

**docs/** — los 8 documentos de referencia, en orden de lectura:
1. `01_contexto_y_vision.md` — por qué este proyecto, para quién, con qué alcance y presupuesto
2. `02_roles_y_permisos.md` — matriz maestra de qué puede hacer cada rol
3. `03_flujo_de_estados.md` — ciclos de vida de venta, producto, cierre de caja y auditoría
4. `04_modulos_y_funciones.md` — especificación completa de los 10 módulos de Fase 1
5. `05_stack_tecnico.md` — arquitectura de las 3 apps (Virikyna Local, Inventario, Gestión)
6. `06_estructura_de_datos.md` — schema SQL completo, triggers, RPCs
7. `07_guia_desarrollo_iterativo.md` — orden de fases de construcción, checklist por fase
8. `08_estilos_y_diseno.md` — sistema de diseño (Quicksand + DM Sans, acento violeta)

**skills/** — 5 skills de Claude, reutilizables para este y futuros proyectos de retail/POS:
- `pos-inventory-architecture`
- `supabase-production-patterns`
- `tauri-react-desktop`
- `powersync-offline-sync`
- `pos-ux-ui-design`

**assets/** — referencias visuales validadas con la clienta:
- `virikyna-como-funciona.html` — explicador interactivo del ciclo de vida (versión para mostrarle a la dueña)
- `comparativo-3-quicksand.html` — la opción de tipografía/color elegida (Quicksand + DM Sans, violeta), como punto de partida real de código para Virikyna Local

## Cómo usar esto en desarrollo

Seguir `07_guia_desarrollo_iterativo.md` fase por fase. Cada fase indica qué documentos adjuntar en el prompt de desarrollo (Claude Code u otro entorno). Instalar las 5 skills antes de empezar — están armadas específicamente para elevar la calidad de este stack (Supabase, Tauri, PowerSync, inventario POS, UX de punto de venta).
