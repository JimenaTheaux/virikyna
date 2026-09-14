import type { ReactNode } from 'react'

// Mismos tokens que apps/virikyna-local/src/components/FormField.tsx, con más padding vertical
// para un target de toque cómodo en celular.
export const inputClass =
  'w-full rounded border border-line bg-surface px-4 py-3.5 font-sans text-body-lg text-ink outline-none focus:border-accent disabled:bg-bg disabled:text-ink-soft'

export const selectClass = inputClass

export function Field({ label, children, hint }: { label: string; children: ReactNode; hint?: string }) {
  return (
    <label className="flex flex-col gap-2">
      <span className="font-sans text-label-md text-ink">{label}</span>
      {children}
      {hint && <span className="font-sans text-label-md text-ink-soft">{hint}</span>}
    </label>
  )
}

export function ErrorText({ children }: { children: ReactNode }) {
  return <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{children}</p>
}
