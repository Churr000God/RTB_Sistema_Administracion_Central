// Molde de lib/tiposAusencia.ts, pero acá el catálogo no es un Record estático: las etiquetas
// dependen de `ventana_meses` (parámetro del sistema, hoy 6 pero configurable), que backend
// devuelve en GET /api/banco-de-horas -- nunca hardcodear "3"/"6" en el frontend. La mitad usa
// piso entero (Math.floor) para espejar el `//` (división entera) que usa
// backend/app/banco_antiguedad.py al cortar el tramo medio -- con ventana impar, la etiqueta debe
// coincidir con el corte real, no redondear a un decimal que el backend nunca usa.
export type TramoAntiguedad = "reciente" | "media" | "fuera_ventana";

export const TRAMOS_ANTIGUEDAD: TramoAntiguedad[] = ["reciente", "media", "fuera_ventana"];

export function etiquetaTramoAntiguedad(tramo: TramoAntiguedad, ventanaMeses: number): string {
  const mitad = Math.floor(ventanaMeses / 2);
  switch (tramo) {
    case "reciente":
      return `0-${mitad}m`;
    case "media":
      return `${mitad}-${ventanaMeses}m`;
    case "fuera_ventana":
      return `${ventanaMeses}+m`;
  }
}

export function descripcionTramoAntiguedad(tramo: TramoAntiguedad, ventanaMeses: number): string {
  const mitad = Math.floor(ventanaMeses / 2);
  switch (tramo) {
    case "reciente":
      return `Deuda de los últimos ${mitad} meses.`;
    case "media":
      return `Deuda de entre ${mitad} y ${ventanaMeses} meses de antigüedad.`;
    case "fuera_ventana":
      return `Deuda de más de ${ventanaMeses} meses -- fuera de la ventana de resolución del banco de horas.`;
  }
}
