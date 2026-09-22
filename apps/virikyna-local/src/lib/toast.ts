// Pub/sub minimalista para mostrar avisos desde cualquier lado (sin Context/Provider) —
// se suscribe el <Toaster /> montado una vez en main.tsx (ver components/Toaster.tsx).
type Listener = (mensaje: string) => void

const listeners = new Set<Listener>()

export function showToast(mensaje: string): void {
  listeners.forEach((listener) => listener(mensaje))
}

export function subscribeToast(listener: Listener): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}
