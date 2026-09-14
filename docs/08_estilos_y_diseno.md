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

**Nunca bajar de `body-md` (16px) para texto operativo** — es el piso de legibilidad para esta app, no el tamaño por defecto del navegador.

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
- **Tablas/listados**: filas altas (mínimo 56px), texto en `body-lg`, nunca `body-md` para el dato principal de una fila.
- **Tarjetas de dashboard**: número protagonista en `headline-md` o `display-card` según jerarquía, la etiqueta que lo describe en `label-bold` uppercase, discreta.
- **Confirmaciones destructivas**: modal con el mismo patrón siempre — botón de cancelar a la izquierda, acción destructiva a la derecha en `error`, nunca al revés entre pantallas.

## 6. Accesibilidad y contexto de uso (resumen — detalle en skill `pos-ux-ui-design`)

- Contraste alto siempre; evitar grises medios en texto que importa.
- Diseñar pensando que el cajero mira la pantalla a ~80cm, bajo luz de local variable, durante horas — no como una app de celular de uso ocasional.
- Vista Admin y vista Cajero muestran densidad de información distinta a propósito, no la misma pantalla con permisos ocultos (ver `02_roles_y_permisos.md`).

## 7. Referencia de implementación

Ver `comparativo-3-quicksand.html` (incluido en este entregable) como referencia de código funcional de esta combinación aplicada a la pantalla de Ventas — es el punto de partida real para el layout de Virikyna Local, no solo una maqueta de referencia.
