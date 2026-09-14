import { IconBuscar } from './icons'

type Props = {
  value: string
  onChange: (value: string) => void
  placeholder: string
}

export function SearchInput({ value, onChange, placeholder }: Props) {
  return (
    <div className="relative">
      <IconBuscar className="pointer-events-none absolute left-3 top-1/2 h-5 w-5 -translate-y-1/2 text-ink-soft" />
      <input
        type="text"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder={placeholder}
        className="w-64 rounded border border-line bg-surface py-3 pl-10 pr-3 font-sans text-body-md text-ink outline-none focus:border-accent"
      />
    </div>
  )
}
