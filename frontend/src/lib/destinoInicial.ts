import type { SesionOut } from "./sesion";

export const RUTA_INICIO = "/inicio";

// Primera pantalla a la que aterriza TODA persona al iniciar sesión: «Inicio». Es una decisión de
// producto (a todos les aparece y los manda al abrir). Desde ahí `InicioPage` muestra, según la sesión
// real, el aviso de acceso en configuración o los accesos a los módulos que sí puede ver. No depende de
// la sesión: si /api/sesion falla, Inicio muestra su propio error con «Reintentar».
export function destinoInicial(): string {
  return RUTA_INICIO;
}

type Banderas = Pick<SesionOut, "puede_ver_modulo_1" | "puede_ver_modulo_2" | "puede_ver_modulo_3"> & {
  puede_ver_terminales?: boolean;
};

export type ModuloVisible = { etiqueta: string; href: string };

// Módulos que la persona puede ver, en el orden del sidebar. Sólo un `true` explícito cuenta.
export function modulosVisibles(sesion: Banderas): ModuloVisible[] {
  const modulos: ModuloVisible[] = [];
  if (sesion.puede_ver_modulo_1 === true) modulos.push({ etiqueta: "Personas y Usuarios", href: "/personas" });
  if (sesion.puede_ver_modulo_2 === true) modulos.push({ etiqueta: "Estructura organizacional", href: "/estructura/areas" });
  if (sesion.puede_ver_modulo_3 === true) modulos.push({ etiqueta: "Tiempo", href: "/tiempo/asignacion-jornada" });
  if (sesion.puede_ver_terminales === true) modulos.push({ etiqueta: "Terminales", href: "/tiempo/terminales" });
  return modulos;
}
