// Listas de selección múltiple (ej. actualización masiva de precios): los ítems "fijados" van
// primero, respetando el orden original dentro de cada grupo.
//
// Se ordena por un conjunto de ids FIJADOS aparte de la selección viva, a propósito: si el orden
// siguiera la selección en tiempo real, cada tilde haría saltar la fila hacia arriba, bajo el dedo
// o el mouse. Quien usa esto actualiza `fijados` en momentos puntuales (al abrir con una selección
// previa, al cambiar la búsqueda) para que lo tildado quede a la vista sin mover filas al tocarlas.
export function fijadosPrimero<T extends { id: string }>(lista: T[], fijados: ReadonlySet<string>): T[] {
  if (fijados.size === 0) return lista
  const primeros: T[] = []
  const resto: T[] = []
  for (const item of lista) (fijados.has(item.id) ? primeros : resto).push(item)
  return [...primeros, ...resto]
}
