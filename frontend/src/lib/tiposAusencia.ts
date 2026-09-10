// Catálogo estático en código, espejo del backend -- no justifica un endpoint propio para 5
// valores fijos. Molde exacto de lib/motivosRevision.ts.
export type TipoAusencia =
  | "vacaciones"
  | "permiso_con_goce"
  | "permiso_sin_goce"
  | "incapacidad"
  | "falta";

export const CATALOGO_TIPO_AUSENCIA: Record<TipoAusencia, { etiqueta: string; descripcion: string }> = {
  vacaciones: { etiqueta: "Vacaciones", descripcion: "Toma el día completo como trabajado." },
  permiso_con_goce: {
    etiqueta: "Permiso con goce",
    descripcion: "Toma el día completo como trabajado, con goce de sueldo.",
  },
  permiso_sin_goce: {
    etiqueta: "Permiso sin goce",
    descripcion: "El día cuenta como no trabajado (0 horas).",
  },
  incapacidad: {
    etiqueta: "Incapacidad",
    descripcion: "Toma el día completo como trabajado, respaldada por documento.",
  },
  falta: {
    etiqueta: "Falta",
    descripcion: "Ausencia no justificada; si no se autoriza, el día cuenta como no trabajado.",
  },
};

export function etiquetaTipoAusencia(tipo: string): string {
  return CATALOGO_TIPO_AUSENCIA[tipo as TipoAusencia]?.etiqueta ?? tipo;
}
