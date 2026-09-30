# 08 — Estilos y Diseño — Virikyna POS

Sistema de diseño validado con la clienta — **Opción 3**: Quicksand (títulos/display) + DM Sans (texto/UI), acento **Teal**.

---

## 1. Logo

- **Isotipo/wordmark:** "Virikyna" en **Milk Days** (fuente de pago, mjtype.com) — asset ya definido, no se re-crea. Versiones disponibles: negro (`Virikyna-NEGRO.png`) y color teal (`Virikyna-COLOR.png`).
- **Ícono de marca (V):** paleta de 6 variantes de color (`Virikyna-ISO-color.png`) — se usa la **V teal** como ícono de marca dentro de la app (favicon, avatar de marca en el header), en línea con el wordmark en color.
- Milk Days **no se usa como fuente de UI** — es exclusiva del logo. Dentro de la app, los títulos usan Quicksand como la fuente que mejor "conversa" con el espíritu redondeado del logo sin sacrificar legibilidad funcional.

## 2. Color

**Primario — Teal** (extraído directo de la versión color del wordmark):

| Token | Hex | Uso |
|---|---|---|
| `accent` | `#3FB9B9` | Botones primarios, elementos activos, foco |
| `accent-dark` | `#237878` | Encabezados de tabla, texto sobre fondo claro con jerarquía alta |
| `accent-darker` | `#163F3F` | Títulos principales, total a pagar, máximo contraste de marca |
| `accent-light` | `#E3F5F5` | Fondos de estado "seleccionado" o "incluido", tags suaves |

**Paleta secundaria** (del resto de la iso de marca — disponible para uso puntual, no como color dominante):

| Nombre | Hex | Uso sugerido |
|---|---|---|
| Verde agua | `#86CAC2` | Alternativa de acento evaluada y descartada para la UI principal — queda disponible para estados de "éxito" o insignias secundarias |
| Amarillo | `#F6F19D` | Alertas suaves, destacados no urgentes |
| Rosa | `#ECABCE` | Categorías, badges decorativos |
| Celeste | `#73CAE9` | Categorías, badges decorativos |
| Violeta | `#B192C4` | Acento anterior (Opción 3 original) — evaluado y reemplazado por el teal del wordmark; queda disponible para variantes decorativas puntuales |

**Neutros y semánticos:**

| Token | Hex | Uso |
|---|---|---|
| `ink` | `#24242B` | Texto principal |
| `ink-soft` | `#6B6570` | Texto secundario, labels |
| `bg` | `#F7F6FA` | Fondo general de la app |
| `surface` | `#FFFFFF` | Tarjetas, tablas, paneles |
| `line` | `#E6E2EA` | Bordes, separadores |
| `error` | `#C0392B` | Acciones destructivas (cancelar, eliminar) |
| `success` | `#4A6F6B` (variante oscura del verde agua) | Confirmaciones, estados positivos |

**Regla de aplicación:** el teal se usa para *acción y jerarquía* (qué tocar, qué es importante ahora), nunca como color de fondo extendido — la app es mayormente clara/neutra con acentos teal puntuales, no una app "toda teal". Esto es intencional: en un mostrador con luz variable, un fondo saturado cansa la vista en turnos largos (ver skill `pos-ux-ui-design`).

## 3. Tipografía

| Uso | Fuente | Peso |
|---|---|---|
| Títulos, totales, números protagonistas | **Quicksand** | 600–700 |
| Texto de UI, tablas, formularios, botones | **DM Sans** | 400–700 |

**Escala tipográfica** (base más grande que un estándar web — pedido explícito de la dueña, la distancia real de lectura en el mostrador es de ~80cm, no los ~40cm de un celular; ver skill `pos-ux-ui-design`):

| Token | Tamaño / interlineado | Fuente | Uso |
|---|---|---|---|
| `display-total` | 52px / 1.0, peso 700 | Quicksand | Total a pagar en Ventas |
| `display-card` | 32px / 1.0, peso 600 | Quicksand | Número protagonista en cards numéricas de dashboard |
| `headline-lg` | 30px / 38px, peso 700 | Quicksand | Título de pantalla ("Factura C", "Inventario") |
| `headline-md` | 22px / 28px, peso 700 | Quicksand | Subtítulos de sección, montos destacados en tablas |
| `body-lg` | 18px / 28px, peso 500 | DM Sans | Texto principal de listas (nombre de producto, cliente) |
| `body-md` | 16px / 24px, peso 400 | DM Sans | Texto general, formularios |
| `label-bold` | 14px / 20px, peso 700 | DM Sans | Botones, encabezados de tabla |
| `label-md` | 13px / 18px, peso 500 | DM Sans | Metadatos, notas secundarias |
| `table-row` | 13px / 18px, peso 400 | DM Sans | Texto de fila de tablas de listado estilo "G" (solo ahí — ver 5.2) |
| `table-head` | 10.5px / 14px, peso 700, `letterSpacing` 0.04em | DM Sans | Encabezado de tablas de listado estilo "G" (solo ahí — ver 5.2) |

**Nunca bajar de `body-md` (16px) para texto operativo** — es el piso de legibilidad para esta app, no el tamaño por defecto del navegador. Única excepción: `table-row` / `table-head` en las tablas de listado de la sección 5.2.

## 4. Espaciado y forma

| Token | Valor |
|---|---|
| `radius-default` | 12px (botones, inputs) |
| `radius-lg` | 16px (tarjetas, paneles) |
| `radius-full` | 999px (pills, avatares) |
| `stack-sm` / `stack-md` / `stack-lg` | 8px / 16px / 32px |
| `padding-card` | 20–24px |
| `gutter-grid` | 16px |

Esquinas redondeadas de forma consistente en toda la app — coherente con el espíritu del logo sin necesidad de usar su tipografía en la UI.

## 5. Componentes — principios (detalle de comportamiento en `04_modulos_y_funciones.md` y skill `pos-ux-ui-design`)

- **Botón primario** (teal sólido): una sola acción protagonista por pantalla (ej. "Cobrar"). Nunca dos botones teal sólido compitiendo en la misma vista.
- **Botón destructivo** (borde/texto `error`, fondo blanco): "Cancelar", "Eliminar" — nunca del mismo peso visual que el botón primario, para que un click apurado no los confunda.
- **Atajos de teclado**: siempre visibles junto a su acción (no ocultos), en `label-md`, mismo patrón en toda la app.
- **Tablas/listados** (revisado — ver "Densidad de tablas" más abajo): filas compactas (~36px, `px-3 py-1.5`), texto en `body-md` con `leading-5` (nunca por debajo de `body-md`/16px). El carrito de Ventas es la excepción — sigue en `body-lg` por ser la lista que el cajero lee mientras cobra.
- **Tarjetas de dashboard**: número protagonista en `headline-md` o `display-card` según jerarquía, la etiqueta que lo describe en `label-bold` uppercase, discreta.
- **Confirmaciones destructivas**: modal con el mismo patrón siempre — botón de cancelar a la izquierda, acción destructiva a la derecha en `error`, nunca al revés entre pantallas.

## 5.1 Densidad de tablas (revisión — resolución responsive)

Ajuste posterior al punto anterior, pedido explícitamente para que las tablas de Facturación e
Inventario entren sin scroll vertical en resoluciones desktop estándar (1366×768 en adelante):

| Elemento | Antes | Ahora |
|---|---|---|
| Encabezado (`th`) | `px-4 py-3` | `px-3 py-2` |
| Celda (`td`) | `px-4 py-2.5` | `px-3 py-1.5` |
| Interlineado del cuerpo | `body-md` (24px) | `body-md leading-5` (20px) |
| Altura de fila resultante | ~56px mínimo forzado | ~36px, sin piso forzado |

El tamaño de fuente **no baja de `body-md` (16px)** — la densidad se gana achicando padding e
interlineado, no el tamaño de letra, para no perder legibilidad a la distancia real de lectura del
mostrador. El contenedor de la tabla sigue con su propio `overflow-auto`: con datos masivos el
scroll interno de la tabla es esperable y correcto, lo que se elimina es el scroll innecesario con
una cantidad normal de filas.

## 5.2 Tablas de listado con acciones por fila (estilo "G")

Rediseño explícito, pedido por la clienta con una referencia visual concreta (captura "G —
Facturación: menú anclado"), para toda tabla de listado con acciones por fila en las 3 apps. Es
una **excepción tipográfica acotada** al 5.1 — no se aplica al carrito de Ventas, formularios ni
texto operativo general, que mantienen el piso de `body-md` (16px) de la sección 3.

| Elemento | Valor |
|---|---|
| Contenedor | `rounded-xl` (usa el `radius-lg` de la sección 4), `shadow-sm` |
| Header (`th`) | `bg-accent-light text-accent-dark uppercase`, tipografía `table-head` (10.5px/14px, peso 700, `letterSpacing` 0.04em) |
| Fila (`tr`) | `py-3` (→ ~42px con `table-row`), pares `bg-table-row-alt`, separador `border-table-divider` |
| Texto de fila | token `table-row` (13px/18px, peso 400), definido en el `tailwind.config.ts` de las 3 apps — va en el `<table>` y lo heredan todas las celdas; montos y badges suman `font-semibold` aparte |
| Ancho de columnas | `table-fixed` + `<colgroup>`: columnas de contenido corto y constante (N°, fecha, montos, estado, checkbox, acciones) con ancho fijo en `rem`, medido sobre el contenido más largo real (ej. `$ 1.234.567,89`, badge "Sin facturar"); columnas de texto variable (cliente, nombre, proveedor, motivo) sin ancho o con `%`, se reparten el resto. Debajo de `xl` (1280px) el padding de celda baja a `px-2` (`max-xl:[&_td]:px-2 max-xl:[&_th]:px-2` en el `<table>`) |
| Badge de estado | pill `rounded-[6px] px-2 py-0.5`, criterio de color (no paleta libre): ámbar `badge-amber-bg`/`badge-amber-text` = pendiente/atención, verde `badge-green-bg`/`badge-green-text` = ok/completo, rojo `badge-red-bg`/`error` = error/anulado, neutro `badge-neutral-bg`/`ink-soft` = inactivo/sin estado — ver componente `EstadoBadge` en `packages/shared` |
| Botón de acciones | "⋮" cuadrado `rounded` ~26×26px, fondo `table-divider` (`#F0F2F3`) — abre `RowActionsMenu` (`packages/shared`), portal anclado con flip hacia arriba si no hay espacio abajo, ítems ícono + texto, cierre en click afuera |

**Regla de menú vs. ícono suelto:** si la fila tiene una sola acción posible, va como ícono suelto
(sin menú); con 2 o más, todas dentro de `RowActionsMenu` — nunca mezclar ícono suelto + menú en
la misma fila. Con cero acciones discretas, la fila puede seguir siendo clickeable a un detalle
(como ya pasa en Facturas de compra).

**Sin scroll horizontal en ningún ancho.** La tabla mide siempre el 100% de su contenedor: nunca
`whitespace-nowrap` en columnas de texto variable (esas llevan `[overflow-wrap:anywhere]`), nunca
`min-w-[...px]` por columna. Validar en 1024px (mínimo de la ventana de Local), 1280px (1920×1080
con escala de Windows al 150%, caso típico de monitor grande en el local), 1366px, 1920px y 2560px —
"se ve bien en la notebook" no alcanza: el ancho que importa es el efectivo en CSS, después de la
escala de Windows, no la resolución física del monitor. El detalle largo de una fila (ej. ítems de
una devolución) va en un modal "Ver detalle", no dentro de la celda.

En Inventario (móvil) el botón "⋮" y cada ítem del menú usan el tamaño `touch` (mínimo 44×44px)
en vez de los ~26px de escritorio.

## 6. Accesibilidad y contexto de uso (resumen — detalle en skill `pos-ux-ui-design`)

- Contraste alto siempre; evitar grises medios en texto que importa.
- Diseñar pensando que el cajero mira la pantalla a ~80cm, bajo luz de local variable, durante horas — no como una app de celular de uso ocasional.
- Vista Admin y vista Cajero muestran densidad de información distinta a propósito, no la misma pantalla con permisos ocultos (ver `02_roles_y_permisos.md`).

## 7. Referencia de implementación

Ver `comparativo-3-quicksand.html` (incluido en este entregable) como referencia de código funcional de esta combinación aplicada a la pantalla de Ventas — es el punto de partida real para el layout de Virikyna Local, no solo una maqueta de referencia.
