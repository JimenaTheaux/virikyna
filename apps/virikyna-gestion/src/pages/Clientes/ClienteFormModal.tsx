import { useState, type FormEvent } from 'react'
import type { Cliente, CondicionIvaCliente } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { friendlyError } from '@virikyna/shared'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass } from '../../components/FormField'

// Necesaria para Factura C (RG 5616) — sin este dato, ARCA rechaza el comprobante para
// cualquier cliente que no sea Consumidor Final. Ver supabase/functions/arca-emitir-factura.
const CONDICION_IVA_LABEL: Record<CondicionIvaCliente, string> = {
  consumidor_final: 'Consumidor Final',
  responsable_inscripto: 'Responsable Inscripto',
  monotributista: 'Monotributista',
  exento: 'Exento',
  no_categorizado: 'No categorizado',
}

type Props = {
  cliente?: Cliente
  onClose: () => void
  onSaved: () => void
}

export function ClienteFormModal({ cliente, onClose, onSaved }: Props) {
  const [razonSocial, setRazonSocial] = useState(cliente?.razon_social ?? '')
  const [nombreFantasia, setNombreFantasia] = useState(cliente?.nombre_fantasia ?? '')
  const [cuit, setCuit] = useState(cliente?.cuit ?? '')
  const [domicilio, setDomicilio] = useState(cliente?.domicilio ?? '')
  const [mail, setMail] = useState(cliente?.mail ?? '')
  const [celular, setCelular] = useState(cliente?.celular ?? '')
  const [condicionIva, setCondicionIva] = useState<CondicionIvaCliente>(
    cliente?.condicion_iva ?? 'consumidor_final',
  )
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

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)

    const razonSocialLimpia = razonSocial.trim()
    const nombreFantasiaLimpio = nombreFantasia.trim()

    if (!razonSocialLimpia && !nombreFantasiaLimpio) {
      setError('Ingresá al menos una razón social o un nombre de fantasía.')
      return
    }

    const payload = {
      razon_social: razonSocialLimpia || null,
      nombre_fantasia: nombreFantasiaLimpio || null,
      cuit: cuit.trim() || null,
      domicilio: domicilio.trim() || null,
      mail: mail.trim() || null,
      celular: celular.trim() || null,
      condicion_iva: condicionIva,
    }

    setSaving(true)
    const { error: dbError } = cliente
      ? await supabase.from('clientes').update(payload).eq('id', cliente.id)
      : await supabase.from('clientes').insert(payload)
    setSaving(false)

    if (dbError) {
      setError(friendlyError(dbError))
      return
    }
    onSaved()
  }

  return (
    <Modal title={cliente ? 'Editar cliente' : 'Nuevo cliente'} onClose={pedirCierre} widthClassName="max-w-[560px]">
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <div className="grid grid-cols-2 gap-stack-md">
          <Field label="Razón social">
            <input
              autoFocus
              value={razonSocial}
              onChange={(e) => setRazonSocial(e.target.value)}
              className={inputClass}
            />
          </Field>
          <Field label="Nombre de fantasía">
            <input
              value={nombreFantasia}
              onChange={(e) => setNombreFantasia(e.target.value)}
              className={inputClass}
            />
          </Field>
        </div>
        <p className="-mt-2 font-sans text-label-md text-ink-soft">
          Ningún dato es obligatorio, salvo cargar al menos uno de los dos nombres de arriba.
        </p>

        <div className="grid grid-cols-2 gap-stack-md">
          <Field label="CUIT">
            <input
              value={cuit}
              onChange={(e) => setCuit(e.target.value.replace(/\D/g, ''))}
              inputMode="numeric"
              className={inputClass}
            />
          </Field>
          <Field label="Condición frente al IVA">
            <select
              value={condicionIva}
              onChange={(e) => setCondicionIva(e.target.value as CondicionIvaCliente)}
              className={inputClass}
            >
              {Object.entries(CONDICION_IVA_LABEL).map(([value, label]) => (
                <option key={value} value={value}>
                  {label}
                </option>
              ))}
            </select>
          </Field>
        </div>

        <div className="grid grid-cols-2 gap-stack-md">
          <Field label="Celular">
            <input value={celular} onChange={(e) => setCelular(e.target.value)} className={inputClass} />
          </Field>
          <Field label="Mail">
            <input type="email" value={mail} onChange={(e) => setMail(e.target.value)} className={inputClass} />
          </Field>
        </div>

        <Field label="Domicilio">
          <input value={domicilio} onChange={(e) => setDomicilio(e.target.value)} className={inputClass} />
        </Field>

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
            disabled={saving}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {saving ? 'Guardando...' : 'Guardar'}
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
