// La gestión de usuarios es exclusiva de Virikyna Gestión (docs/04, módulo 9) — a propósito no
// se duplica acá. Esta pantalla solo existe para que un admin que abre Configuración desde la
// Caja entienda adónde ir, en vez de encontrar un módulo vacío sin explicación.
export function ConfiguracionPage() {
  return (
    <section className="flex h-full flex-col rounded-lg bg-surface p-card shadow-sm">
      <h1 className="font-display text-headline-lg text-accent-darker">Configuración</h1>
      <p className="mt-1 font-sans text-body-md text-ink-soft">Usuarios, roles y ajustes generales.</p>
      <div className="mt-6 flex flex-1 flex-col items-center justify-center gap-2 rounded border border-dashed border-line px-6 text-center font-sans text-body-md text-ink-soft">
        <p>La gestión de usuarios (crear, editar, blanquear contraseña, desactivar) se hace desde <strong>Virikyna Gestión</strong>.</p>
        <p>Virikyna Local se usa para operar el mostrador — para administrar usuarios, entrá a Virikyna Gestión con tu cuenta de admin.</p>
      </div>
    </section>
  )
}
