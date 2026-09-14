import { ProductosTab } from './Inventario/ProductosTab'

export function InventarioPage() {
  return (
    <section className="flex h-full flex-col rounded-lg bg-surface p-card shadow-sm">
      <h1 className="font-display text-headline-lg text-accent-darker">Inventario</h1>

      <div className="mt-stack-md flex-1 overflow-hidden">
        <ProductosTab />
      </div>
    </section>
  )
}
