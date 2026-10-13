// Re-export: la implementación vive en packages/shared (lib/comprobante.ts, misma para Local y Gestión).
export {
  FORMA_PAGO_LABEL,
  lineasFormaPago,
  linkGmail,
  linkWhatsApp,
  mensajeEnvio,
  normalizarCelularArg,
  type DatosComprobante,
  type ItemComprobante,
} from '@virikyna/shared'
