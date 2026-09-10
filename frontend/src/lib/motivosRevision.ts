// Espejo en frontend de backend/app/catalogo_motivos_revision.py (SCJ-DEC-07). Catálogo estático
// en código en ambos lados -- no justifica un endpoint propio.
//
// reloj_no_sincronizado/persona_inactiva/dia_cerrado/fuera_de_horario: los escribe el trigger
// fn_marca_valida_revision al insertar la marca. paridad_impar: lo agrega el batch de cierre de
// día. plantilla_desconocida: nace en Operación, fuera de este repo.
const ETIQUETAS: Record<string, string> = {
  reloj_no_sincronizado: "Reloj no sincronizado",
  persona_inactiva: "Persona inactiva",
  dia_cerrado: "Día ya cerrado",
  fuera_de_horario: "Fuera de horario",
  paridad_impar: "Paridad impar de marcas",
  plantilla_desconocida: "Plantilla biométrica desconocida",
};

// fn_ausencia_resuelve_excepcion (SQL) concatena " — resuelto por ausencia autorizada, carga
// tardía" (u otro texto) al motivo original al resolver una excepción de día. Sin partir por
// este separador, toda excepción resuelta cae al string crudo sin traducir.
const SEPARADOR_SUFIJO = " — ";

export function etiquetaMotivo(motivo: string): string {
  const indice = motivo.indexOf(SEPARADOR_SUFIJO);
  if (indice === -1) return ETIQUETAS[motivo] ?? motivo;

  const clave = motivo.slice(0, indice);
  const sufijo = motivo.slice(indice);
  return `${ETIQUETAS[clave] ?? clave}${sufijo}`;
}
