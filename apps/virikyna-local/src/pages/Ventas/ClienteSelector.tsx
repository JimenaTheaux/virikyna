import { useEffect, useRef, useState } from 'react'
import type { Cliente } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import type { ClienteSeleccionado } from './types'

type Props = {
  cliente: ClienteSeleccionado | null
  onChange: (cliente: ClienteSeleccionado | null) => void
}

// "Cambiar cliente (consumidor final / cta. cte.)" — módulo 3 de docs/04_modulos_y_funciones.md.
export function ClienteSelector({ cliente, onChange }: Props) {
  const [clientes, setClientes] = useState<Cliente[]>([])
  const [abierto, setAbierto] = useState(false)
  const [filtro, setFiltro] = useState('')
  const boxRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    supabase
      .from('clientes')
      .select('*')
      .eq('activo', true)
      .order('razon_social', { ascending: true, nullsFirst: false })
      .then(({ data }) => setClientes((data ?? []) as Cliente[]))
  }, [])

  useEffect(() => {
    function onClickFuera(e: MouseEvent) {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) setAbierto(false)
    }
    document.addEventListener('mousedown', onClickFuera)
    return () => document.removeEventListener('mousedown', onClickFuera)
  }, [])

  const filtrados = clientes.filter((c) =>
    (c.razon_social ?? c.nombre_fantasia ?? '').toLowerCase().includes(filtro.toLowerCase()),
  )

  function elegir(c: Cliente | null) {
    onChange(
      c
        ? { id: c.id, nombre: c.razon_social ?? c.nombre_fantasia ?? 'Sin nombre', mail: c.mail, celular: c.celular }
        : null,
    )
    setAbierto(false)
    setFiltro('')
  }

  return (
    <div ref={boxRef} className="relative">
      <button
        type="button"
        onClick={() => setAbierto((a) => !a)}
        className="flex items-center gap-2 rounded-full border border-line bg-bg px-4 py-2 font-sans text-label-bold text-ink-soft hover:border-accent"
      >
        {cliente ? cliente.nombre : 'Consumidor final'}
      </button>
      {abierto && (
        <div className="absolute right-0 z-10 mt-1 w-72 overflow-hidden rounded-lg border border-line bg-surface shadow-sm">
          <input
            autoFocus
            value={filtro}
            onChange={(e) => setFiltro(e.target.value)}
            placeholder="Buscar cliente..."
            className="w-full border-b border-line px-4 py-3 font-sans text-body-md text-ink outline-none focus:border-accent"
          />
          <div className="max-h-60 overflow-auto">
            <button
              type="button"
              onClick={() => elegir(null)}
              className="block w-full px-4 py-2.5 text-left font-sans text-body-md text-ink hover:bg-bg"
            >
              Consumidor final
            </button>
            {filtrados.map((c) => (
              <button
                key={c.id}
                type="button"
                onClick={() => elegir(c)}
                className="block w-full px-4 py-2.5 text-left font-sans text-body-md text-ink hover:bg-bg"
              >
                {c.razon_social ?? c.nombre_fantasia}
              </button>
            ))}
            {filtrados.length === 0 && (
              <p className="px-4 py-3 font-sans text-body-md text-ink-soft">Sin coincidencias.</p>
            )}
          </div>
        </div>
      )}
    </div>
  )
}
