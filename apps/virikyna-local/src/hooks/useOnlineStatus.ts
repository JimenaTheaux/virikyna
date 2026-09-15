import { useEffect, useState } from 'react'

// navigator.onLine + eventos 'online'/'offline' alcanza para este local (un solo
// registro, cortes de conexión cortos y esporádicos) — no hace falta un ping activo
// contra Supabase para esto, ver docs/07_guia_desarrollo_iterativo.md.
export function useOnlineStatus(): boolean {
  const [online, setOnline] = useState(navigator.onLine)

  useEffect(() => {
    function handleOnline() {
      setOnline(true)
    }
    function handleOffline() {
      setOnline(false)
    }

    window.addEventListener('online', handleOnline)
    window.addEventListener('offline', handleOffline)
    return () => {
      window.removeEventListener('online', handleOnline)
      window.removeEventListener('offline', handleOffline)
    }
  }, [])

  return online
}
