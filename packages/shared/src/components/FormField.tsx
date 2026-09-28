import type { ReactNode } from 'react'

export const inputClass =
  'rounded border border-line bg-surface px-4 py-2.5 font-sans text-body-md text-ink outline-none focus:border-accent disabled:bg-bg disabled:text-ink-soft'

export const selectClass = inputClass

export function Field({
  label,
  children,
  hint,
  compact,
}: {
  label: string
  children: ReactNode
  hint?: string
  compact?: boolean
}) {
  return (
    <label className={`flex flex-col ${compact ? 'gap-1' : 'gap-2'}`}>
      <span className="font-sans text-label-md text-ink">{label}</span>
      {children}
      {hint && <span className="font-sans text-label-md text-ink-soft">{hint}</span>}
    </label>
  )
}

export function ErrorText({ children }: { children: ReactNode }) {
  return <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{children}</p>
}
