---
name: pos-ux-ui-design
description: Principios de UX/UI específicos para software de punto de venta (POS) y gestión comercial en retail — distancia de lectura real, tolerancia a errores bajo presión de tiempo, prevención de fraude por diseño, accesibilidad para turnos largos, y patrones de interfaz para cajeros vs. administradores. Usar al diseñar o revisar cualquier pantalla de venta/checkout, dashboard de negocio, o flujo operativo de un sistema de punto de venta — complementa (no reemplaza) la skill genérica frontend-design.
---

# UX/UI para sistemas de punto de venta

Un POS no es una app de consumo. El contexto de uso es tan distinto que aplicar patrones estándar de UX mobile/web produce una interfaz que se ve bien en una demo y falla en el mostrador real.

## La distancia de lectura real es el doble de lo que se asume

El benchmark estándar de tamaño de fuente/botones para apps móviles asume una distancia de lectura de ~40cm (el usuario sostiene el dispositivo). En un mostrador de POS, la distancia real observada es de ~80cm o más — la pantalla está fija sobre el mostrador y el cajero no siempre puede reposicionarla. Esto no es una preferencia estética: es la razón concreta detrás de pedidos como "letras grandes" que hacen los dueños de comercio. Diseñar la tipografía y los targets táctiles para esa distancia, no para el estándar de una app de teléfono.

## La velocidad de interacción es mucho mayor que en apps de consumo

Un usuario de app de consumo navega a su propio ritmo. Un cajero con cola de clientes no — la velocidad de tap/click observada en cajeros es notablemente mayor que la de un usuario promedio, porque hay presión social y de tiempo real detrás de cada transacción. Consecuencias de diseño:
- Las acciones más frecuentes (agregar producto, cobrar, cambiar forma de pago) no pueden depender de menús anidados o confirmaciones innecesarias.
- Los atajos de teclado no son un "nice to have" para power users — son la diferencia entre atender rápido o generar cola. Definirlos explícitamente para las 5-8 acciones más frecuentes de la pantalla de venta.
- La interfaz tiene que tolerar clicks rápidos y repetidos sin romperse (doble-submit, carreras de estado) — esto es tanto un problema de ingeniería como de diseño.

## Los errores no son solo un costo de UX — son un vector de fraude

En una app de consumo, "permitir deshacer fácilmente" es casi siempre correcto. En un POS, una corrección de venta demasiado fácil de hacer (anular, editar cantidad después de cobrado, aplicar un descuento sin registro) es exactamente el mecanismo que se usa para sustraer dinero de la caja. Balance a diseñar conscientemente:
- Las correcciones legítimas (cliente se arrepiente de un ítem antes de cobrar) deben ser fáciles.
- Las correcciones después de cobrado, los descuentos, y cualquier acción que mueva dinero o stock sin una venta real detrás, deben quedar **siempre** registradas con usuario y motivo — no como fricción para el cajero honesto, sino como trazabilidad para cuando haga falta revisar.
- Nunca diseñar una acción "silenciosa" que mueva stock o dinero sin dejar rastro, aunque parezca una mejora de velocidad.

## Diseñar para dos perfiles de usuario, no uno

En la práctica hay cajeros que desarrollan destreza (usan atajos, escanean con una mano mientras operan con la otra, encuentran el camino más rápido) y cajeros que operan a ritmo estándar sin buscar atajos. Una interfaz que solo expone el camino largo (todo a click, sin atajos) castiga al usuario avanzado; una que solo expone atajos sin equivalente visual castiga al nuevo. Siempre exponer ambos caminos al mismo tiempo: el botón visible y grande, y el atajo de teclado/gesto para quien ya lo aprendió — nunca uno solo.

## Turnos largos: diseñar para fatiga visual, no para una sesión corta

Un cajero mira esa pantalla durante horas seguidas, típicamente bajo iluminación de local (a veces con reflejos sobre la pantalla) y alternando la mirada entre el mostrador, el cliente y la pantalla constantemente. Esto pesa más que en cualquier app de uso ocasional:
- Contraste alto entre texto y fondo, evitar grises medios para texto importante.
- Evitar temas oscuros saturados si el local tiene mala iluminación o luz directa sobre el mostrador — un tema claro con buen contraste suele ser más legible bajo luz variable que uno oscuro.
- El número que más importa en cada pantalla (el total a cobrar, en Ventas) debe ser el elemento visualmente más dominante, sin competencia de otros elementos del mismo tamaño o color.

## Diseñar para ambas manos, sin asumir diestro

Cajeros zurdos existen, y la posición física del mostrador/lector de código de barras no siempre es simétrica ni reubicable. Evitar layouts que asuman que la mano dominante siempre "estorba" en el mismo lugar (ej. un botón de acción principal escondido detrás de donde cae la mano al escanear) — es un detalle chico que en la práctica genera roce físico real con el hardware del mostrador.

## Jerarquía distinta para Admin vs. Cajero — no es solo permisos, es densidad de información

El rol Admin necesita panorama (números, tendencias, comparaciones) porque su trabajo es decidir. El rol Cajero necesita velocidad de acción porque su trabajo es ejecutar, muchas veces por hora. La misma pantalla (ej. un dashboard) no debería mostrarle a ambos la misma densidad de información:
- Admin: números con contexto (variación vs. período anterior, gráficos, desgloses).
- Cajero: números simples y accesos directos grandes tipo grid de botones — sin análisis, sin comparaciones, solo lo accionable ahora mismo.

## Consistencia entre pantallas, literal

El mismo tipo de acción (confirmar, cancelar, eliminar) tiene que verse y comportarse igual en todos los módulos del sistema — mismo color para "acción destructiva", misma posición relativa de "confirmar" vs. "cancelar" en todos los modales, mismo patrón de confirmación para todas las eliminaciones. En un sistema operado bajo presión de tiempo, la inconsistencia entre pantallas no es un detalle estético — genera errores reales (confirmar algo pensando que era el botón de siempre, en una pantalla donde el layout se invirtió).

## Checklist de revisión para cualquier pantalla nueva del POS

- [ ] ¿El texto y los targets están dimensionados para lectura a ~80cm, no a distancia de celular?
- [ ] ¿Las 5-8 acciones más frecuentes tienen atajo de teclado, además de su botón visible?
- [ ] ¿Alguna acción mueve stock o dinero sin quedar registrada con usuario/motivo?
- [ ] ¿El elemento más importante de la pantalla (total, stock crítico) es visualmente el más dominante?
- [ ] ¿La vista de Admin y la de Cajero muestran distinta densidad de información, no la misma pantalla con permisos ocultos?
- [ ] ¿Confirmar/cancelar/eliminar se ven y se ubican igual en todos los módulos?
- [ ] ¿Se probó con buena luz y con luz de local real (reflejos, contraluz)?
