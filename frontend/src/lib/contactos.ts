// Correos de contacto que la app muestra en pantallas de error/ayuda. Configurables por
// variable de entorno (VITE_* — de build, no de runtime, mismo gotcha que supabaseClient); ver
// CLAUDE.md. Fallbacks: buzones reales de RTB (RTB-TIN-13), provisional hasta que existan rh@/direccion@.
export const CONTACTOS = {
  rh: {
    nombre: "Recursos Humanos",
    correo: import.meta.env.VITE_CONTACTO_RH_CORREO ?? "tbadillob@refacrtb.com.mx",
  },
  sistemas: {
    nombre: "Sistemas",
    correo: import.meta.env.VITE_CONTACTO_SISTEMAS_CORREO ?? "sistemas@refacrtb.com.mx",
  },
  administracion: {
    nombre: "Administración",
    correo:
      import.meta.env.VITE_CONTACTO_ADMINISTRACION_CORREO ?? "finanzas@refacrtb.com.mx",
  },
  direccion: {
    nombre: "Dirección",
    correo: import.meta.env.VITE_CONTACTO_DIRECCION_CORREO ?? "tbadillob@refacrtb.com.mx",
  },
} as const;
