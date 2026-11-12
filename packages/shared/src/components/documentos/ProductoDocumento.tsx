// Ficha de artículo como documento de la bandeja (docs/73) — Inventario de Local y Gestión. El
// formulario es el de cada app (renderFormulario); acá se maneja qué pasa al restaurarlo:
//   - El artículo no cambió en la base: queda exactamente como estaba (pestaña, scroll, campos).
//   - Cambió y la ficha no tiene cambios sin guardar: se vuelve a armar con los datos de hoy, en la
//     misma pestaña.
//   - Cambió y hay cambios sin guardar: no se pisa nada; se avisa qué cambió ("Cambió algo…").

import { Fragment, useRef, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Proveedor } from '../../../types/database'
import { formatCurrency } from '../../../lib/format'
import { formatCantidad } from '../../../lib/cargaInicial'
import { SELECT_PRODUCTOS_INVENTARIO, stockTotal, type ProductoConRelaciones } from '../../../lib/inventario'
import { avisarCambioDatos } from '../../../lib/cambiosDatos'
import type { FormularioProductoRender, PestanaProducto } from '../inventario/ProductosTab'
import { useAlRestaurar, useDocumento } from './contexto'
import type { BandejaApi } from './DocumentosAbiertos'

function firma(p: ProductoConRelaciones) {
  const stock = [...p.stock_ubicaciones]
    .sort((a, b) => a.ubicacion.localeCompare(b.ubicacion))
    .map((s) => `${s.ubicacion}:${Number(s.cantidad)}`)
    .join(',')
  return `${p.updated_at}|${stock}`
}

function diferencias(antes: ProductoConRelaciones, ahora: ProductoConRelaciones): string[] {
  const avisos: string[] = []
  const monto = (n: number | null) => (n === null ? 'sin costo' : formatCurrency(Number(n)))
  if (antes.nombre !== ahora.nombre) avisos.push(`Nombre: ${antes.nombre} → ${ahora.nombre}`)
  if ((antes.marca ?? '') !== (ahora.marca ?? '')) avisos.push(`Marca: ${antes.marca ?? '—'} → ${ahora.marca ?? '—'}`)
  if (Number(antes.costo ?? NaN) !== Number(ahora.costo ?? NaN) && !(antes.costo === null && ahora.costo === null)) {
    avisos.push(`Costo: ${monto(antes.costo)} → ${monto(ahora.costo)}`)
  }
  if (Number(antes.margen_1) !== Number(ahora.margen_1) || Number(antes.margen_2) !== Number(ahora.margen_2)) {
    avisos.push(`Márgenes: ${antes.margen_1}% / ${antes.margen_2}% → ${ahora.margen_1}% / ${ahora.margen_2}%`)
  }
  if (Number(antes.precio_venta) !== Number(ahora.precio_venta)) {
    avisos.push(`Precio de venta: ${formatCurrency(Number(antes.precio_venta))} → ${formatCurrency(Number(ahora.precio_venta))}`)
  }
  if (antes.estado !== ahora.estado) avisos.push(`Estado: ${antes.estado} → ${ahora.estado}`)
  if (Number(antes.stock_minimo) !== Number(ahora.stock_minimo)) {
    avisos.push(`Stock mínimo: ${formatCantidad(Number(antes.stock_minimo))} → ${formatCantidad(Number(ahora.stock_minimo))}`)
  }
  if (stockTotal(antes) !== stockTotal(ahora)) avisos.push(`Stock: ${formatCantidad(stockTotal(antes))} → ${formatCantidad(stockTotal(ahora))}`)
  if (avisos.length === 0) avisos.push('Otro usuario guardó cambios en este artículo.')
  avisos.push('Si guardás, queda lo que ves en el formulario.')
  return avisos
}

type Props = {
  supabase: SupabaseClient
  bandeja: BandejaApi
  productoInicial: ProductoConRelaciones
  proveedores: Proveedor[]
  renderFormulario: FormularioProductoRender
  onClose: () => void
}

function ProductoDocumento({ supabase, bandeja, productoInicial, proveedores, renderFormulario, onClose }: Props) {
  const doc = useDocumento()
  const [producto, setProducto] = useState(productoInicial)
  // Sube para volver a armar el formulario con el artículo de hoy (sin cambios sin guardar).
  const [version, setVersion] = useState(0)
  const [avisos, setAvisos] = useState<string[]>([])
  const pestanaRef = useRef<PestanaProducto>('datos')
  const cambiosRef = useRef(false)
  cambiosRef.current = doc?.cambios ?? false

  useAlRestaurar(() => {
    void (async () => {
      const { data, error } = await supabase.from('productos').select(SELECT_PRODUCTOS_INVENTARIO).eq('id', producto.id).maybeSingle()
      if (error) return // sin red: queda lo que estaba
      if (!data) {
        setAvisos(['El artículo ya no existe: se eliminó mientras estaba minimizado.'])
        return
      }
      const ahora = data as unknown as ProductoConRelaciones
      if (firma(ahora) === firma(producto)) return
      if (!cambiosRef.current) {
        setProducto(ahora)
        setAvisos([])
        setVersion((v) => v + 1)
        return
      }
      setAvisos(diferencias(producto, ahora))
    })()
  })

  return (
    <Fragment key={version}>
      {renderFormulario({
        producto,
        proveedores,
        onClose,
        onSaved: () => {
          onClose()
          avisarCambioDatos('productos')
        },
        onStockChanged: () => avisarCambioDatos('productos'),
        onEliminado: (nombre) => {
          onClose()
          avisarCambioDatos('productos', `Se eliminó ${nombre}.`)
        },
        onEditarExistente: (id) => void abrirProductoPorId(bandeja, { supabase, id, proveedores, renderFormulario }),
        documento: {
          minimizable: true,
          tabInicial: pestanaRef.current,
          onTabChange: (t) => {
            pestanaRef.current = t
          },
          avisoCambios: avisos,
        },
      })}
    </Fragment>
  )
}

type Abrir = {
  supabase: SupabaseClient
  producto: ProductoConRelaciones
  proveedores: Proveedor[]
  renderFormulario: FormularioProductoRender
}

// Un artículo = un documento: abrirlo otra vez desde la lista lo trae al frente.
export function abrirProducto(bandeja: BandejaApi, { supabase, producto, proveedores, renderFormulario }: Abrir) {
  return bandeja.abrir({
    clave: `producto:${producto.id}`,
    tipo: 'producto',
    etiqueta: `Art. ${producto.nombre}`,
    render: ({ cerrar }) => (
      <ProductoDocumento
        supabase={supabase}
        bandeja={bandeja}
        productoInicial={producto}
        proveedores={proveedores}
        renderFormulario={renderFormulario}
        onClose={cerrar}
      />
    ),
  })
}

// Aviso de código duplicado → "Editar el existente": se abre ese artículo como otro documento.
async function abrirProductoPorId(
  bandeja: BandejaApi,
  { supabase, id, proveedores, renderFormulario }: Omit<Abrir, 'producto'> & { id: string },
) {
  if (bandeja.documentos.some((d) => d.clave === `producto:${id}`)) {
    bandeja.restaurar(`producto:${id}`)
    return
  }
  const { data } = await supabase.from('productos').select(SELECT_PRODUCTOS_INVENTARIO).eq('id', id).maybeSingle()
  if (data) abrirProducto(bandeja, { supabase, producto: data as unknown as ProductoConRelaciones, proveedores, renderFormulario })
}
