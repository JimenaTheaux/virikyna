import { useMemo, useState } from 'react'
import { coincideBusquedaProducto } from './productoBusqueda'
import { fijadosPrimero } from './listaSeleccion'
import { PAGINA_LISTA } from '../src/components/MostrarMas'

// Lo mínimo para listar, buscar y tildar productos en una acción masiva.
export type ProductoSeleccionable = {
  id: string
  nombre: string
  marca: string | null
  codigo_barras: string | null
  codigo_interno: string | null
  proveedor: { razon_social: string } | null
}

// Selección de productos de las acciones masivas (Actualizar precios, docs/34; IVA, docs/47):
// búsqueda por nombre/marca/código/proveedor, tildes y paginado "Mostrar más". Lo tildado se
// muestra primero (fijadosPrimero): la selección con la que se abrió y, cada vez que cambia la
// búsqueda, lo que estaba tildado hasta ese momento.
export function useSeleccionProductos<P extends ProductoSeleccionable>(productos: P[], seleccionInicial: string[] = []) {
  const [seleccion, setSeleccion] = useState<Set<string>>(new Set(seleccionInicial))
  const [busqueda, setBusqueda] = useState('')
  const [visibles, setVisibles] = useState(PAGINA_LISTA)
  const [fijados, setFijados] = useState<Set<string>>(new Set(seleccionInicial))

  const productosFiltrados = useMemo(() => {
    const q = busqueda.trim().toLowerCase()
    const filtrados = !q
      ? productos
      : productos.filter(
          (p) => coincideBusquedaProducto(p, q) || (p.proveedor?.razon_social ?? '').toLowerCase().includes(q),
        )
    return fijadosPrimero(filtrados, fijados)
  }, [productos, busqueda, fijados])

  function buscar(texto: string) {
    setBusqueda(texto)
    setFijados(new Set(seleccion))
    setVisibles(PAGINA_LISTA)
  }

  function toggle(id: string) {
    setSeleccion((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  return {
    seleccion,
    toggle,
    busqueda,
    buscar,
    productosVisibles: productosFiltrados.slice(0, visibles),
    sinResultados: productosFiltrados.length === 0,
    restantes: productosFiltrados.length - visibles,
    verMas: () => setVisibles((n) => n + PAGINA_LISTA),
  }
}

export type SeleccionProductos<P extends ProductoSeleccionable = ProductoSeleccionable> = ReturnType<
  typeof useSeleccionProductos<P>
>
