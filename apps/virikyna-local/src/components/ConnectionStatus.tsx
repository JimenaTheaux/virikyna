import { useOnlineStatus } from '../hooks/useOnlineStatus'

// Discreto cuando todo está bien (un puntito, nada de texto) — se nota cuando
// realmente importa: sin conexión, con texto y color de alerta.
export function ConnectionStatus() {
  const online = useOnlineStatus()

  if (online) {
    return (
      <div
        className="flex items-center gap-2 rounded-full bg-bg px-3 py-2"
        title="Conectado"
      >
        <span className="h-2 w-2 rounded-full bg-success" />
      </div>
    )
  }

  return (
    <div
      className="flex items-center gap-2 rounded-full bg-error/10 px-4 py-2 font-sans text-label-bold text-error"
      title="Sin conexión a internet"
    >
      <span className="h-2 w-2 flex-shrink-0 rounded-full bg-error" />
      Sin conexión
    </div>
  )
}
