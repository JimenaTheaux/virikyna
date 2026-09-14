// Carga una imagen (URL o import de asset) como HTMLImageElement listo para dibujar —
// lo usan los generadores de comprobante en PDF (jsPDF addImage) y JPG (canvas drawImage).
export function cargarImagen(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve(img)
    img.onerror = () => reject(new Error(`No se pudo cargar la imagen: ${src}`))
    img.src = src
  })
}
