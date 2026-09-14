// Un <input type="number"> enfocado cambia de valor si el mouse pasa la rueda por encima —
// un accidente típico al scrollear la pantalla que termina modificando un monto sin querer.
// Se bloquea acá, una sola vez por app (llamado desde main.tsx), en vez de agregar un onWheel
// a cada input numérico de las 3 apps — quedan decenas repartidos en Inventario, Caja, Ventas, etc.
// preventDefault() cancela el paso nativo del input; blur() saca el foco así el resto del gesto
// de scroll (si el mouse no se movió) sigue afectando la página normalmente, no vuelve a quedar
// atrapado en el input.
export function disableNumberInputScroll() {
  document.addEventListener(
    'wheel',
    (e) => {
      const target = e.target
      if (target instanceof HTMLInputElement && target.type === 'number' && document.activeElement === target) {
        e.preventDefault()
        target.blur()
      }
    },
    { passive: false },
  )
}
