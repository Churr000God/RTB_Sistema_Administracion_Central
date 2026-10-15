// Folio del expediente (personas.expediente.documento_ref). El formato real lo impone la base
// (db/ddl/71_expediente_documento_ref_formato_rh_eit.sql, ck_expediente_documento_ref_formato):
// RTB-RH-EIT-<año de 4 dígitos>-<número de expediente>. La expresión es la MISMA que la de la base.
export const PATRON_DOCUMENTO_REF = /^RTB-RH-EIT-[0-9]{4}-[0-9]+$/;

export const EJEMPLO_DOCUMENTO_REF = "RTB-RH-EIT-2026-06";

export const AYUDA_DOCUMENTO_REF = `Formato RTB-RH-EIT-<año>-<número>, por ejemplo ${EJEMPLO_DOCUMENTO_REF} · folio del expediente físico`;

export const MENSAJE_DOCUMENTO_REF_INVALIDO = `El folio debe tener el formato RTB-RH-EIT-<año de 4 dígitos>-<número>, por ejemplo ${EJEMPLO_DOCUMENTO_REF}.`;

export function documentoRefValido(valor: string): boolean {
  return PATRON_DOCUMENTO_REF.test(valor);
}

// Textos LOCALES por situación para los errores de POST/PATCH /api/personas: el detail del servidor no
// se pinta (sólo se usa para reconocer que el rechazo fue por el folio).
export const MENSAJE_PERSONA_DUPLICADA = "CURP, RFC, NSS o número de documento ya está en uso por otra persona.";
export const MENSAJE_PERSONA_DATOS_INVALIDOS = "Alguno de los datos no es válido; revísalos y vuelve a intentarlo.";
export const MENSAJE_PERSONA_SIN_PERMISO = "No tienes permiso para esta acción.";

export type ErrorPersona = {
  texto: string;
  campoDocumentoRef: boolean;
  // El alta insertó la persona pero falló el expediente: reenviar el formulario duplicaría la CURP.
  personaYaCreada: boolean;
};

const MARCA_PERSONA_SIN_EXPEDIENTE = "quedó registrada sin expediente";

export async function errorDePersona(respuesta: Response, generico: string): Promise<ErrorPersona> {
  let detail: unknown = null;
  try {
    detail = (await respuesta.json())?.detail;
  } catch {
    // cuerpo vacío o no JSON: cae al texto por status
  }
  const texto = typeof detail === "string" && detail.trim().length > 0 ? detail : null;
  if (respuesta.status === 409) {
    const t = texto ?? MENSAJE_PERSONA_DUPLICADA;
    return { texto: t, campoDocumentoRef: false, personaYaCreada: t.includes(MARCA_PERSONA_SIN_EXPEDIENTE) };
  }
  if (respuesta.status === 422) {
    // Un folio mal formado: el detail menciona el formato RTB-RH-EIT y el error se marca en el campo.
    if (texto && texto.includes("RTB-RH-EIT")) return { texto, campoDocumentoRef: true, personaYaCreada: texto.includes(MARCA_PERSONA_SIN_EXPEDIENTE) };
    const t = texto ?? MENSAJE_PERSONA_DATOS_INVALIDOS;
    return { texto: t, campoDocumentoRef: false, personaYaCreada: t.includes(MARCA_PERSONA_SIN_EXPEDIENTE) };
  }
  if (respuesta.status === 403) return { texto: MENSAJE_PERSONA_SIN_PERMISO, campoDocumentoRef: false, personaYaCreada: false };
  return { texto: generico, campoDocumentoRef: false, personaYaCreada: false };
}
