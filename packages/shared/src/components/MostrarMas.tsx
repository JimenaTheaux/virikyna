// Paginación "Mostrar más" para listas dentro de modales y sheets: en vez de un recuadro de altura
// fija con scroll propio (mini-scroll), la lista crece con el contenido y el que scrollea es el
// modal/página. Para no renderizar cientos de filas de golpe, se muestran de a PAGINA_LISTA.
export const PAGINA_LISTA = 25

type Props = {
  restantes: number
  onClick: () => void
  // 'touch': alto de 48px para pantallas de celular.
  size?: 'compact' | 'touch'
}

export function MostrarMas({ restantes, onClick, size = 'compact' }: Props) {
  if (restantes <= 0) return null
  return (
    <button
      type="button"
      onClick={onClick}
      className={`w-full rounded border border-line bg-surface font-sans text-label-bold text-accent-dark hover:bg-accent-light active:bg-accent-light ${
        size === 'touch' ? 'min-h-12' : 'py-2'
      }`}
    >
      Mostrar más ({restantes} restante{restantes === 1 ? '' : 's'})
    </button>
  )
}
