// Punto de entrada del paquete compartido: tipos de base de datos (ver docs/06_estructura_de_datos.md)
// más la lógica de negocio y wiring de auth que usan por igual Virikyna Local y Virikyna Inventario.

export * from './types/database'
export * from './lib/format'
export * from './lib/supabaseErrors'
export * from './lib/inventario'
export * from './lib/facturasCompra'
export * from './lib/arcaFacturacion'
export * from './lib/historialPrecio'
export * from './lib/perfiles'
export * from './lib/cargarImagen'
export * from './lib/numberInput'
export * from './lib/productoBusqueda'
export * from './lib/useDebouncedValue'
export * from './auth/createAuthController'
export * from './src/components/Footer'
export * from './src/components/VentasDelDiaTab'
export * from './src/components/BottomSheet'
