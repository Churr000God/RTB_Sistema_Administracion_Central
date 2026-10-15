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

// Errores de POST/PATCH /api/personas. Los 409 y 422 de este router traen un `detail` de TEXTO fijo y
// específico que SÍ se pinta, tal cual y como texto plano: qué dato chocó (CURP, RFC, NSS, folio) o el formato
// del folio. Si no viene un texto (p. ej. el 422 de validación de FastAPI trae una lista) se usa un texto local
// por status. El 403 y cualquier otro status (incluido el 502 de una respuesta sin id) NO pintan el detail:
// usan un texto local o el genérico.
export const MENSAJE_PERSONA_DUPLICADA = "CURP, RFC, NSS o número de documento ya está en uso por otra persona.";
export const MENSAJE_PERSONA_DATOS_INVALIDOS = "Alguno de los datos no es válido; revísalos y vuelve a intentarlo.";
export const MENSAJE_PERSONA_SIN_PERMISO = "No tienes permiso para dar de alta personas.";

export type ErrorPersona = { texto: string; campoDocumentoRef: boolean };

export async function errorDePersona(respuesta: Response, generico: string): Promise<ErrorPersona> {
  let detail: unknown = null;
  try {
    detail = (await respuesta.json())?.detail;
  } catch {
    // cuerpo vacío o no JSON: cae al texto por status
  }
  const texto = typeof detail === "string" && detail.trim().length > 0 ? detail : null;
  if (respuesta.status === 409) return { texto: texto ?? MENSAJE_PERSONA_DUPLICADA, campoDocumentoRef: false };
  if (respuesta.status === 422) {
    // Un folio mal formado: el detail menciona el formato RTB-RH-EIT y el error se marca en el campo.
    if (texto && texto.includes("RTB-RH-EIT")) return { texto, campoDocumentoRef: true };
    return { texto: texto ?? MENSAJE_PERSONA_DATOS_INVALIDOS, campoDocumentoRef: false };
  }
  if (respuesta.status === 403) return { texto: MENSAJE_PERSONA_SIN_PERMISO, campoDocumentoRef: false };
  return { texto: generico, campoDocumentoRef: false };
}
