import { useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Producto } from '../types/database'
import { friendlyError } from './supabaseErrors'
import { ERROR_PRODUCTO_CON_HISTORIAL, eliminarProducto } from './inventario'

type Opciones = {
  supabase: SupabaseClient
  producto?: Pick<Producto, 'id' | 'nombre' | 'estado'> // undefined en un alta: el hook no hace nada
  onEliminado: (nombre: string) => void
  onInactivado: () => void
  onError: (mensaje: string) => void
}

// Eliminar un producto (docs/48) desde los formularios de las 3 apps: confirmar → RPC. Si el
// servidor responde "tiene historial" (VKH01) pasa al aviso que ofrece Inactivar. El servidor valida
// todo de nuevo (admin, historial): una venta que entra mientras se confirma no se pierde.
// Cada formulario dibuja los dos diálogos con su ConfirmDialog (textos en textosEliminarProducto).
export function useEliminarProducto({ supabase, producto, onEliminado, onInactivado, onError }: Opciones) {
  const [paso, setPaso] = useState<'confirmar' | 'historial' | null>(null)
  const [procesando, setProcesando] = useState(false)
  const yaInactivo = producto?.estado === 'inactivo'

  async function eliminar() {
    if (!producto || procesando) return
    setProcesando(true)
    const { error } = await eliminarProducto(supabase, producto.id)
    setProcesando(false)
    if (!error) {
      setPaso(null)
      onEliminado(producto.nombre)
      return
    }
    if (error.code === ERROR_PRODUCTO_CON_HISTORIAL) {
      setPaso('historial')
      return
    }
    setPaso(null)
    onError(friendlyError(error))
  }

  async function inactivar() {
    if (!producto || procesando) return
    if (yaInactivo) {
      setPaso(null)
      return
    }
    setProcesando(true)
    const { error } = await supabase.from('productos').update({ estado: 'inactivo' }).eq('id', producto.id)
    setProcesando(false)
    setPaso(null)
    if (error) {
      onError(friendlyError(error))
      return
    }
    onInactivado()
  }

  return {
    paso,
    procesando,
    pedir: () => setPaso('confirmar'),
    cancelar: () => setPaso(null),
    eliminar,
    inactivar,
    textos: textosEliminarProducto(producto?.nombre ?? '', yaInactivo),
  }
}

export function textosEliminarProducto(nombre: string, yaInactivo: boolean) {
  return {
    confirmar: { title: 'Eliminar producto', mensaje: `Eliminar ${nombre}. No se puede deshacer.`, confirmLabel: 'Eliminar' },
    historial: {
      title: 'No se puede eliminar',
      mensaje: yaInactivo
        ? 'Tiene movimientos registrados. No se puede eliminar. Ya está inactivo.'
        : 'Tiene movimientos registrados. No se puede eliminar.',
      confirmLabel: yaInactivo ? 'Entendido' : 'Inactivar',
    },
  }
}
