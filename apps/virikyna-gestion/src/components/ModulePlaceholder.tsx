type Props = {
  title: string
  description: string
}

export function ModulePlaceholder({ title, description }: Props) {
  return (
    <section className="flex h-full flex-col rounded-lg bg-surface p-card shadow-sm">
      <h1 className="font-display text-headline-lg text-accent-darker">{title}</h1>
      <p className="mt-1 font-sans text-body-md text-ink-soft">{description}</p>
      <div className="mt-6 flex flex-1 items-center justify-center rounded border border-dashed border-line font-sans text-body-md text-ink-soft">
        Módulo en construcción
      </div>
    </section>
  )
}
