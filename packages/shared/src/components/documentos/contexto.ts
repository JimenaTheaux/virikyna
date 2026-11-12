// Contexto de cada documento de la bandeja (docs/73). Archivo aparte del provider para que Modal,
// DropdownFlotante y los formularios lo lean sin importar el provider (que a su vez usa Modal).

import { createContext, useContext, useEffect, useRef } from 'react'

export type InfoDocumento = {
  etiqueta?: string // texto del chip ("Factura · AGABELLA · 3 ítems")
  cambios?: boolean // punto teal en el chip
}

export type DocumentoCtx = {
  clave: string
  minimizado: boolean
  // Lo que reportó el Modal raíz: con cambios, la ✕ del chip restaura antes de preguntar.
  cambios: boolean
  // Sube en cada restauración (0 = recién abierto): useAlRestaurar.
  restauraciones: number
  minimizar: () => void
  // Los registra el Modal raíz del documento (el que tiene `minimizable`).
  reportar: (info: InfoDocumento) => void
  registrarCierre: (pedirCierre: (() => void) | null) => void
  // Al cerrar sesión: "Guardar borrador" de la factura con cambios, antes de vaciar la bandeja.
  registrarGuardado: (guardar: (() => Promise<unknown> | void) | null) => void
  // Otra clave con la que se reconoce el mismo documento (ej. el id de su borrador): abrir esa
  // clave trae este documento al frente en vez de duplicarlo.
  registrarAlias: (alias: string) => () => void
  // Al minimizar, si el foco no puede volver a donde estaba en la página, va al chip.
  enfocarChip: () => void
}

export const DocumentoContext = createContext<DocumentoCtx | null>(null)

// null = no es un documento de la bandeja (un modal común, como hasta ahora).
export function useDocumento(): DocumentoCtx | null {
  return useContext(DocumentoContext)
}

// Todo lo que se dibuja con portal adentro de un documento (modales anidados, desplegables) se
// oculta junto con él.
export function useDocumentoOculto(): boolean {
  return useContext(DocumentoContext)?.minimizado ?? false
}

// Corre `alRestaurar` cada vez que el documento vuelve de minimizado (no al abrirlo).
export function useAlRestaurar(alRestaurar: () => void) {
  const restauraciones = useContext(DocumentoContext)?.restauraciones ?? 0
  const ref = useRef(alRestaurar)
  ref.current = alRestaurar
  useEffect(() => {
    if (restauraciones > 0) ref.current()
  }, [restauraciones])
}

// Registra un alias mientras el componente está montado y el alias no cambia.
export function useAliasDocumento(alias: string | null) {
  const doc = useContext(DocumentoContext)
  const registrar = doc?.registrarAlias
  useEffect(() => {
    if (!registrar || !alias) return
    return registrar(alias)
  }, [registrar, alias])
}

// ─── Estado global (sin Provider) para lo que vive fuera del árbol de la bandeja ──────────────
// - Ventas (Local): con un documento visible encima, su teclado global no actúa.
// - Aviso de actualización de Local y beforeunload de Gestión: un documento minimizado con
//   cambios sale de la pila de cambiosSinGuardar (no frena la navegación), pero igual se pierde al
//   reiniciar o cerrar la pestaña.

let documentoVisible = false
let documentosConCambios = false

export function hayDocumentoVisible(): boolean {
  return documentoVisible
}

export function hayDocumentosConCambios(): boolean {
  return documentosConCambios
}

export function marcarEstadoBandeja(estado: { visible: boolean; conCambios: boolean }) {
  documentoVisible = estado.visible
  documentosConCambios = estado.conCambios
}
