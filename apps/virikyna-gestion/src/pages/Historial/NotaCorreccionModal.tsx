import { useEffect, useState, type FormEvent } from 'react'
import type { CierreCaja } from '@virikyna/shared'
import { formatFecha, friendlyError } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { agregarNotaCorreccion } from '../../lib/historial'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass, selectClass } from '../../components/FormField'

type Props = {
  onClose: () => void
  onSaved: () => void
}

// Cierre Z ya validado: no se reabre, solo admite una nota de corrección visible en el Historial
// (docs/04_modulos_y_funciones.md, módulo 10). Como validar_cierre_z no genera fila propia en
// auditoria, esta es la única vía para dejar la primera nota sobre un cierre — no depende de
// hacer click sobre una fila existente.
export function NotaCorreccionModal({ onClose, onSaved }: Props) {
  const [cierres, setCierres] = useState<CierreCaja[]>([])
  const [cierreId, setCierreId] = useState('')
  const [nota, setNota] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [confirmCerrar, setConfirmCerrar] = useState(false)

  function pedirCierre() {
    if (dirty) {
      setConfirmCerrar(true)
    } else {
      onClose()
    }
  }

  useEffect(() => {
    async function cargar() {
      setLoading(true)
      const { data, error: dbError } = await supabase
        .from('cierres_caja')
        .select('*')
        .eq('tipo', 'z')
        .eq('estado_validacion', 'validado')
        .order('turno_fecha', { ascending: false })
      if (dbError) {
        setError(friendlyError(dbError))
      } else {
        const lista = (data ?? []) as CierreCaja[]
        setCierres(lista)
        if (lista[0]) setCierreId(lista[0].id)
      }
      setLoading(false)
    }
    cargar()
  }, [])

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)

    if (!cierreId) {
      setError('Elegí un Cierre Z validado.')
      return
    }
    if (!nota.trim()) {
      setError('La nota no puede estar vacía.')
      return
    }

    setSaving(true)
    const { error: rpcError } = await agregarNotaCorreccion(cierreId, nota.trim())
    setSaving(false)

    if (rpcError) {
      setError(friendlyError(rpcError))
      return
    }
    onSaved()
  }

  return (
    <Modal title="Nota de corrección sobre un Cierre Z" onClose={pedirCierre} widthClassName="max-w-[480px]">
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <p className="font-sans text-body-md text-ink-soft">
          No reabre el cierre ni cambia ningún número — solo deja constancia, visible en el Historial.
        </p>

        {loading && <p className="font-sans text-body-md text-ink-soft">Cargando cierres...</p>}

        {!loading && cierres.length === 0 && (
          <p className="font-sans text-body-md text-ink-soft">No hay ningún Cierre Z validado todavía.</p>
        )}

        {!loading && cierres.length > 0 && (
          <>
            <Field label="Cierre Z">
              <select value={cierreId} onChange={(e) => setCierreId(e.target.value)} className={selectClass}>
                {cierres.map((c) => (
                  <option key={c.id} value={c.id}>
                    {formatFecha(c.turno_fecha)}
                  </option>
                ))}
              </select>
            </Field>

            <Field label="Nota">
              <input autoFocus value={nota} onChange={(e) => setNota(e.target.value)} className={inputClass} />
            </Field>
          </>
        )}

        {error && <ErrorText>{error}</ErrorText>}

        <div className="flex justify-end gap-3">
          <button
            type="button"
            onClick={pedirCierre}
            className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg"
          >
            Cancelar
          </button>
          <button
            type="submit"
            disabled={saving || cierres.length === 0}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {saving ? 'Guardando...' : 'Agregar nota'}
          </button>
        </div>
      </form>

      {confirmCerrar && (
        <ConfirmDialog
          title="Cerrar sin guardar"
          mensaje="Hay cambios sin guardar en este formulario. ¿Querés cerrar de todos modos?"
          confirmLabel="Cerrar sin guardar"
          onCancel={() => setConfirmCerrar(false)}
          onConfirm={onClose}
        />
      )}
    </Modal>
  )
}
