// Correos de contacto que la app muestra en pantallas de error/ayuda. Configurables por
// variable de entorno (VITE_* — de build, no de runtime, mismo gotcha que supabaseClient) para
// no hardcodear datos de la empresa ficticia en el código; ver CLAUDE.md.
export const CONTACTOS = {
  rh: {
    nombre: "Recursos Humanos",
    correo: import.meta.env.VITE_CONTACTO_RH_CORREO ?? "rh@distribuidoracentral.mx",
  },
  sistemas: {
    nombre: "Sistemas",
    correo: import.meta.env.VITE_CONTACTO_SISTEMAS_CORREO ?? "sistemas@distribuidoracentral.mx",
  },
  administracion: {
    nombre: "Administración",
    correo:
      import.meta.env.VITE_CONTACTO_ADMINISTRACION_CORREO ?? "administracion@distribuidoracentral.mx",
  },
  direccion: {
    nombre: "Dirección",
    correo: import.meta.env.VITE_CONTACTO_DIRECCION_CORREO ?? "direccion@distribuidoracentral.mx",
  },
} as const;
