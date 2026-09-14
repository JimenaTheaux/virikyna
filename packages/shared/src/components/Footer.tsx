import decidataLogo from '../assets/decidata-logo-black.png'

export function Footer({ prominent = false }: { prominent?: boolean }) {
  const year = new Date().getFullYear()

  if (prominent) {
    return (
      <footer className="mt-auto flex flex-wrap items-center justify-center gap-2 pt-2 font-body text-xs text-ink-soft">
        <img src={decidataLogo} alt="deciDATA" className="h-4 w-auto opacity-70" />
        <span className="font-semibold text-ink">deciDATA</span>
        <span>© {year} · Todos los derechos reservados</span>
      </footer>
    )
  }

  return (
    <footer className="static mt-8 flex flex-wrap items-center justify-center gap-2 border-t border-line bg-bg py-3 font-body text-[11px] text-ink-soft md:fixed md:inset-x-0 md:bottom-0 md:z-30 md:mt-0 md:h-8 md:flex-nowrap md:px-4 md:py-0">
      <img src={decidataLogo} alt="deciDATA" className="h-[14px] w-auto opacity-60" />
      <span>deciDATA</span>
      <span>© {year} · Todos los derechos reservados</span>
    </footer>
  )
}
