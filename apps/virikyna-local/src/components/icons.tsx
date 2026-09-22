type IconProps = { className?: string; filled?: boolean }

// `filled` = variante rellena para el ítem de nav activo (sidebar). Sin filled,
// se mantiene el trazo outline original usado en el resto de la app.
function iconAttrs(filled?: boolean) {
  return {
    viewBox: '0 0 24 24',
    fill: filled ? 'currentColor' : 'none',
    stroke: 'currentColor',
    strokeWidth: filled ? 1.5 : 2,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
  }
}

export function IconVentas({ className, filled }: IconProps) {
  return (
    <svg {...iconAttrs(filled)} className={className}>
      <circle cx="9" cy="20" r="1" />
      <circle cx="18" cy="20" r="1" />
      <path d="M3 4h2l2.6 12.4a2 2 0 0 0 2 1.6h7.8a2 2 0 0 0 2-1.6L21 8H6" />
    </svg>
  )
}

export function IconInventario({ className, filled }: IconProps) {
  return (
    <svg {...iconAttrs(filled)} className={className}>
      <path d="M21 8 12 3 3 8l9 5 9-5Z" />
      <path d="M3 8v8l9 5 9-5V8" />
      <path d="M12 13v8" />
    </svg>
  )
}

export function IconDashboard({ className, filled }: IconProps) {
  return (
    <svg {...iconAttrs(filled)} className={className}>
      <rect x="3" y="3" width="8" height="8" rx="1.5" />
      <rect x="13" y="3" width="8" height="5" rx="1.5" />
      <rect x="13" y="11" width="8" height="10" rx="1.5" />
      <rect x="3" y="14" width="8" height="7" rx="1.5" />
    </svg>
  )
}

export function IconClientes({ className, filled }: IconProps) {
  return (
    <svg {...iconAttrs(filled)} className={className}>
      <circle cx="9" cy="8" r="3.5" />
      <path d="M2.5 20a6.5 6.5 0 0 1 13 0" />
      <circle cx="17.5" cy="9" r="2.7" />
      <path d="M15.8 13.2A5.2 5.2 0 0 1 21.5 18" />
    </svg>
  )
}

export function IconProveedores({ className, filled }: IconProps) {
  return (
    <svg {...iconAttrs(filled)} className={className}>
      <path d="M2.5 6h11v9h-11Z" />
      <path d="M13.5 10h4l3 3.5V15h-7Z" />
      <circle cx="7" cy="17.5" r="1.6" />
      <circle cx="16.5" cy="17.5" r="1.6" />
    </svg>
  )
}

export function IconFacturacion({ className, filled }: IconProps) {
  return (
    <svg {...iconAttrs(filled)} className={className}>
      <path d="M6 2.5h9l3 3V21a.5.5 0 0 1-.5.5H6a.5.5 0 0 1-.5-.5V3a.5.5 0 0 1 .5-.5Z" />
      <path d="M15 2.5V6h3.5" />
      <path d="M8.5 12h7M8.5 15.5h7M8.5 8.5h4" />
    </svg>
  )
}

export function IconVerDetalle({ className }: IconProps) {
  return (
    <svg {...iconAttrs(false)} className={className}>
      <path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7-10-7-10-7Z" />
      <circle cx="12" cy="12" r="3" />
    </svg>
  )
}

export function IconEnviar({ className }: IconProps) {
  return (
    <svg {...iconAttrs(false)} className={className}>
      <path d="M21 3 3 10.5l7.5 3L14 21l7-18Z" />
      <path d="M10.5 13.5 21 3" />
    </svg>
  )
}

export function IconBuscar({ className }: IconProps) {
  return (
    <svg {...iconAttrs(false)} className={className}>
      <circle cx="10.5" cy="10.5" r="6.5" />
      <path d="m20 20-4.35-4.35" />
    </svg>
  )
}

export function IconCambiarUsuario({ className }: IconProps) {
  return (
    <svg {...iconAttrs(false)} className={className}>
      <path d="M16 3.5a5.5 5.5 0 1 1 0 11 5.5 5.5 0 0 1 0-11Z" />
      <path d="M8 21v-1.5A5.5 5.5 0 0 1 13.5 14H14" />
      <path d="M3 8h6" />
      <path d="M6.5 5.5 9 8l-2.5 2.5" />
    </svg>
  )
}

export function IconCierreCaja({ className, filled }: IconProps) {
  return (
    <svg {...iconAttrs(filled)} className={className}>
      <rect x="3" y="6" width="18" height="13" rx="1.5" />
      <path d="M3 10.5h18" />
      <circle cx="12" cy="14.5" r="2.3" />
      <path d="M8 6V4.5A1.5 1.5 0 0 1 9.5 3h5A1.5 1.5 0 0 1 16 4.5V6" />
    </svg>
  )
}

export function IconAbrirCaja({ className, filled }: IconProps) {
  return (
    <svg {...iconAttrs(filled)} className={className}>
      <rect x="3" y="10" width="18" height="10" rx="1.5" />
      <path d="M3 10V7a1.5 1.5 0 0 1 1.5-1.5h5L12 8h7.5A1.5 1.5 0 0 1 21 9.5V10" />
      <path d="M12 13.5v3M10.3 15.2h3.4" />
    </svg>
  )
}

export function IconNotas({ className, filled }: IconProps) {
  return (
    <svg {...iconAttrs(filled)} className={className}>
      <path d="M4 4h12l4 4v12H4Z" />
      <path d="M16 4v4h4" />
      <path d="M8 12h8M8 15.5h5" />
    </svg>
  )
}

export function IconConfiguracion({ className, filled }: IconProps) {
  return (
    <svg {...iconAttrs(filled)} className={className}>
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.6V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.9 1.7 1.7 0 0 0-1.6-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.9.3H9a1.7 1.7 0 0 0 1-1.6V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.6 1.7 1.7 0 0 0 1.9-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.9V9a1.7 1.7 0 0 0 1.6 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.6 1Z" />
    </svg>
  )
}
