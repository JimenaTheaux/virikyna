import { useEffect, useState } from 'react'
import { subscribeToast } from '../lib/toast'

type ToastItem = { id: number; mensaje: string }

let siguienteId = 0
const DURACION_MS = 3500

// Montado una sola vez en main.tsx, fuera de las rutas, para que sobreviva la navegación.
export function Toaster() {
  const [items, setItems] = useState<ToastItem[]>([])

  useEffect(() => {
    return subscribeToast((mensaje) => {
      const id = siguienteId++
      setItems((prev) => [...prev, { id, mensaje }])
      setTimeout(() => {
        setItems((prev) => prev.filter((item) => item.id !== id))
      }, DURACION_MS)
    })
  }, [])

  if (items.length === 0) return null

  return (
    <div className="pointer-events-none fixed bottom-6 right-6 z-50 flex flex-col gap-2">
      {items.map((item) => (
        <div
          key={item.id}
          className="pointer-events-auto rounded-lg bg-ink px-4 py-3 font-sans text-label-bold text-white shadow-lg"
        >
          {item.mensaje}
        </div>
      ))}
    </div>
  )
}
