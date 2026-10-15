import type { SesionOut } from "./sesion";

export const RUTA_INICIO = "/inicio";

// Primera pantalla a la que debe aterrizar quien acaba de iniciar sesión. Sigue el orden del sidebar:
// Personas (módulo 1), Estructura (módulo 2), Tiempo (módulo 3) y Terminales. Sin ningún módulo visible
// va a /inicio. Si la sesión no cargó (null) se conserva el comportamiento histórico (/personas): es
// sólo UX, la autorización real es la RLS/backend.
export function destinoInicial(sesion: Pick<SesionOut, "puede_ver_modulo_1" | "puede_ver_modulo_2" | "puede_ver_modulo_3"> & {
  puede_ver_terminales?: boolean;
} | null): string {
  if (!sesion) return "/personas";
  if (sesion.puede_ver_modulo_1) return "/personas";
  if (sesion.puede_ver_modulo_2) return "/estructura/areas";
  if (sesion.puede_ver_modulo_3) return "/tiempo/asignacion-jornada";
  if (sesion.puede_ver_terminales) return "/tiempo/terminales";
  return RUTA_INICIO;
}
