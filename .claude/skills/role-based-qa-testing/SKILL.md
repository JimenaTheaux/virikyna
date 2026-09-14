---
name: role-based-qa-testing
description: Metodología de testing funcional para sistemas de gestión/negocio con múltiples roles (ej. admin vs. operador) — cómo dividir casos de prueba entre lo que puede automatizar un agente y lo que necesita ojo humano, cómo probar límites de permisos (no solo el camino feliz), y cómo armar un checklist de QA completo antes de un lanzamiento. Usar al preparar el testing de un sistema ya desarrollado, al armar un plan de QA antes de ir a producción, al verificar qué puede y no puede hacer cada rol, o al testear una app que combina backend con hardware/dispositivos reales (lectores, cámaras, apps móviles).
---

# QA funcional basado en roles

## El error más común: testear solo el camino feliz

Casi todo el mundo prueba que un admin puede hacer lo que un admin debe hacer. Casi nadie prueba sistemáticamente que **cada rol no-privilegiado no puede hacer lo que no debería** — y ahí es donde viven los bugs de seguridad y de negocio más costosos. Un plan de QA completo tiene, por cada acción del sistema, tantos casos de prueba como roles existen — no uno.

## Las 4 capas donde un permiso puede fallar

Un permiso "andando" no es un solo hecho — es que las cuatro capas coincidan. Probar cada una por separado, nunca asumir que si una está bien las demás también:

1. **UI**: ¿el botón o la pantalla está oculta para el rol que no debería verla?
2. **Guard de ruta/cliente**: ¿se puede llegar a esa pantalla escribiendo la URL a mano o navegando directo, aunque no haya botón visible?
3. **Función/RPC del backend**: ¿la función rechaza explícitamente al rol equivocado con un error claro, o confía en que el frontend ya filtró?
4. **Política de base de datos (RLS o equivalente)**: ¿el dato está protegido aunque alguien salte el backend y pegue directo contra la base con las credenciales del cliente?

Un permiso que solo funciona en la capa 1 (UI oculta) no es un permiso — es una sugerencia. El caso de prueba real es: loguearse con el rol restringido e intentar la acción por las 4 vías, no solo mirar si el botón está.

## Clasificación de casos de prueba

Por cada módulo o funcionalidad, cubrir estas categorías — no alcanza con una sola:

- **Camino feliz**: el flujo principal, con datos válidos, sale como se espera.
- **Límites de permisos**: la misma acción, probada con cada rol del sistema (ver arriba).
- **Validaciones y errores esperados**: campos obligatorios vacíos, formatos inválidos, límites de negocio (ej. un motivo obligatorio que falta, un monto negativo donde no corresponde).
- **Casos de borde de datos**: montos en cero, stock que llega a negativo, fechas límite, el primer registro de un tipo (¿qué pasa si la lista está vacía?).
- **Trazabilidad**: si el sistema tiene auditoría/historial, confirmar que la acción quedó registrada con los datos correctos — no asumirlo, consultarlo.
- **Persistencia entre sesiones**: cerrar y volver a abrir la app, ¿el estado se mantiene donde debe?
- **Offline / sincronización** (si el sistema es local-first): probar con la conexión cortada a propósito, no solo con buena conexión.

## Qué le corresponde a un agente vs. a un humano

No todo el QA se puede delegar, y no todo hace falta hacerlo a mano — dividir bien ahorra tiempo real:

**Le corresponde a un agente (Claude Code u otro):**
- Todo lo que se puede verificar por código o consulta directa: llamar una función con distintos usuarios/roles y confirmar el código de error correcto, correr builds y tests automatizados, verificar con consultas que una política de base de datos bloquea lo que debe bloquear, confirmar que una acción generó la fila esperada en un log de auditoría.
- Flujos completos de punta a punta que se puedan simular por código (crear un registro, seguir su ciclo de vida, verificar el estado final) sin necesitar juicio visual.
- Cosas repetitivas: probar la misma acción con cada uno de los roles del sistema, una por una, sistemáticamente.

**Le corresponde a un humano:**
- Juicio visual: ¿la pantalla se ve bien?, ¿la información importante se lee a simple vista?, ¿el flujo se siente natural o hay fricción?
- Hardware real: lectores de código de barras, cámaras de celular, impresoras — un agente no puede probar esto por más acceso a código que tenga.
- Dispositivos reales, no simuladores: un navegador de escritorio no reemplaza probar en un celular real (Android e iOS son casos distintos), ni un emulador reemplaza la app instalada de verdad.
- Decisiones de negocio: "¿esto tiene sentido para cómo trabajamos en el local?" es una pregunta que solo puede responder quien conoce el negocio, no el agente que escribió el código.

## Formato de checklist

Cada caso de prueba, sin importar quién lo ejecute, necesita cuatro datos como mínimo — sin esto, un "no funcionó" no sirve para nada:

```
[ ] Acción: qué se hizo exactamente
    Rol: con qué usuario/rol se probó
    Esperado: qué tendría que haber pasado
    Resultado: OK / Falló — si falló, qué pasó en realidad
```

Agrupar los casos por módulo, no por tipo de prueba — así quien testea recorre el sistema de forma natural (como lo usaría en la vida real) en vez de saltar entre categorías abstractas.

## Reporte de bugs encontrados durante QA

No corregir un bug apenas se encuentra, en medio de la sesión de testing — mezcla el rol de "probar" con el de "arreglar" y hace perder el hilo de qué falta testear. Documentar cada bug con sus pasos de reproducción exactos, seguir probando el resto del checklist, y recién después abrir una sesión de desarrollo aparte para corregir todo lo encontrado (ver skill `dev-prompting`: diagnóstico separado del arreglo, y un bug no se mezcla con la funcionalidad que se estaba construyendo).

## Qué NO cubre un build sin errores

Que el proyecto compile o pase `npm run build` confirma que el código es sintácticamente válido — no confirma que la lógica de negocio ni los permisos sean correctos. Un sistema puede compilar perfecto y dejar que un rol restringido haga algo que no debería. Nunca reemplazar el checklist funcional por "el build pasó".
