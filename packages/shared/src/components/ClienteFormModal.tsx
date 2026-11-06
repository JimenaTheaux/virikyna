import { useEffect, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Cliente, CondicionIvaCliente } from '../../types/database'
import { friendlyError } from '../../lib/supabaseErrors'
import { CONDICION_IVA_LABEL } from '../../lib/cuentaCorrienteCliente'
import { Modal } from './Modal'
import { ConfirmDialog } from './ConfirmDialog'
import { Field, ErrorText, inputClass } from './FormField'

type Props = {
  supabase: SupabaseClient
  cliente?: Cliente
  // docs/68: "Cuenta interna" + usuario vinculado. Solo Gestión (admin): la base además lo exige
  // (trg_proteger_tipo_cliente). En Local no se muestra (D2: en la venta no se distingue).
  permitirCuentaInterna?: boolean
  onClose: () => void
  onSaved: () => void
}

// Alta y edición de un cliente (docs/04, módulo 8). Igual en Local y Gestión: escribe la tabla
// clientes directo (RLS clientes_todos); tipo interno/externo lo cambia solo un admin (docs/68).
export function ClienteFormModal({ supabase, cliente, permitirCuentaInterna = false, onClose, onSaved }: Props) {
  const [razonSocial, setRazonSocial] = useState(cliente?.razon_social ?? '')
  const [nombreFantasia, setNombreFantasia] = useState(cliente?.nombre_fantasia ?? '')
  const [cuit, setCuit] = useState(cliente?.cuit ?? '')
  const [domicilio, setDomicilio] = useState(cliente?.domicilio ?? '')
  const [mail, setMail] = useState(cliente?.mail ?? '')
  const [celular, setCelular] = useState(cliente?.celular ?? '')
  const [condicionIva, setCondicionIva] = useState<CondicionIvaCliente>(
    cliente?.condicion_iva ?? 'consumidor_final',
  )
  const [interno, setInterno] = useState(cliente?.tipo === 'interno')
  const [perfilId, setPerfilId] = useState(cliente?.perfil_id ?? '')
  const [usuarios, setUsuarios] = useState<{ id: string; nombre: string }[]>([])
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    if (!permitirCuentaInterna) return
    void supabase
      .from('perfiles_publico')
      .select('id, nombre')
      .order('nombre')
      .then(({ data }) => setUsuarios((data ?? []) as { id: string; nombre: string }[]))
  }, [supabase, permitirCuentaInterna])
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

    // Mismo chequeo que chk_cliente_tiene_nombre en el schema: al menos un nombre identificatorio.
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
      ...(permitirCuentaInterna
        ? { tipo: interno ? ('interno' as const) : ('externo' as const), perfil_id: interno && perfilId ? perfilId : null }
        : {}),
    }

    setSaving(true)
    const { error: dbError } = cliente
      ? await supabase.from('clientes').update(payload).eq('id', cliente.id)
      : await supabase.from('clientes').insert(payload)
    setSaving(false)

    if (dbError) {
      setError(
        dbError.code === '23505' && dbError.message.includes('ux_clientes_perfil')
          ? 'Ese usuario ya está vinculado a otro cliente.'
          : friendlyError(dbError),
      )
      return
    }
    onSaved()
  }

  return (
    <Modal title={cliente ? 'Editar cliente' : 'Nuevo cliente'} onClose={pedirCierre} cambiosSinGuardar={dirty} widthClassName="max-w-[560px]">
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

        {permitirCuentaInterna && (
          <fieldset className="flex flex-col gap-stack-sm rounded-lg border border-line p-4">
            <legend className="px-1 font-sans text-label-bold text-ink">Cuenta interna</legend>
            <label className="flex cursor-pointer items-center justify-between gap-3">
              <span className="flex flex-col">
                <span className="font-sans text-body-md text-ink">Es dueña o empleado</span>
                <span className="font-sans text-label-md text-ink-soft">
                  Sus compras a cuenta corriente no se cobran: las revisás con descuento por ítem y las finalizás (se descuenta
                  del sueldo).
                </span>
              </span>
              <span className="relative inline-flex flex-shrink-0 items-center">
                <input
                  type="checkbox"
                  role="switch"
                  checked={interno}
                  onChange={(e) => setInterno(e.target.checked)}
                  className="peer sr-only"
                />
                <span
                  aria-hidden="true"
                  className="block h-5 w-9 rounded-full bg-line transition peer-checked:bg-accent peer-focus-visible:outline peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-accent-dark"
                />
                <span
                  aria-hidden="true"
                  className="absolute left-0.5 h-4 w-4 rounded-full bg-surface shadow-sm transition peer-checked:translate-x-4"
                />
              </span>
            </label>
            {interno && (
              <Field label="Usuario del sistema (opcional)" hint="Para saber qué usuario es esta persona.">
                <select value={perfilId} onChange={(e) => setPerfilId(e.target.value)} className={inputClass}>
                  <option value="">Sin usuario vinculado</option>
                  {usuarios.map((u) => (
                    <option key={u.id} value={u.id}>
                      {u.nombre}
                    </option>
                  ))}
                </select>
              </Field>
            )}
            {cliente && cliente.tipo !== (interno ? 'interno' : 'externo') && (
              <p role="status" className="font-sans text-label-md text-ink-soft">
                Aplica a las ventas que se hagan desde ahora. Las ya registradas quedan como están.
              </p>
            )}
          </fieldset>
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
