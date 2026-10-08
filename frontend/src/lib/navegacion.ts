// Navegación completa del navegador envuelta para poder verificarla en pruebas (jsdom no navega).
export function irA(ruta: string): void {
  window.location.href = ruta;
}
