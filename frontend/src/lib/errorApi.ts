import { apiFetch } from "./apiClient";

// Error de una petición a la API que CONSERVA el cuerpo completo. Varios 409/422/503 del módulo de
// terminales traen datos hermanos de `detail` que la pantalla necesita (consentimiento_vigente,
// no_elegibles, valor_actual): con un simple `throw new Error(detail)` se perderían.
export class ErrorApi extends Error {
  status: number;
  // Sólo si el servidor mandó `detail` como texto (los mensajes fijos de backend). Nunca se
  // interpreta como HTML: la UI lo pinta como texto plano.
  detail: string | null;
  cuerpo: Record<string, unknown> | null;

  constructor(status: number, detail: string | null, cuerpo: Record<string, unknown> | null) {
    super(detail ?? `Error ${status}`);
    this.name = "ErrorApi";
    this.status = status;
    this.detail = detail;
    this.cuerpo = cuerpo;
  }
}

export async function leerErrorApi(respuesta: Response): Promise<ErrorApi> {
  let cuerpo: Record<string, unknown> | null = null;
  try {
    const datos: unknown = await respuesta.json();
    if (datos !== null && typeof datos === "object" && !Array.isArray(datos)) {
      cuerpo = datos as Record<string, unknown>;
    }
  } catch {
    // cuerpo vacío o no JSON (HTML de un proxy, etc.)
  }
  const detail = typeof cuerpo?.detail === "string" ? cuerpo.detail : null;
  return new ErrorApi(respuesta.status, detail, cuerpo);
}

// fetch + JSON que lanza ErrorApi ante 4xx/5xx, falla de red (status 0) o un 2xx que no es JSON.
export async function apiJson<T>(path: string, init?: RequestInit): Promise<T> {
  let respuesta: Response;
  try {
    respuesta = await apiFetch(path, init);
  } catch {
    throw new ErrorApi(0, null, null);
  }
  if (!respuesta.ok) throw await leerErrorApi(respuesta);
  try {
    return (await respuesta.json()) as T;
  } catch {
    throw new ErrorApi(respuesta.status, null, null);
  }
}

// Texto de error para mostrar al usuario. Sólo 403/409/422 traen mensajes FIJOS de negocio de
// backend (contrato §6) y se muestran tal cual; 503 tiene su mensaje propio; con cualquier otro
// status, cuerpo ilegible o un error que no es de la API se usa `generico`: un detail inesperado
// (errores internos, ids, nombres de tabla) nunca llega a pantalla.
export function mensajeDeNegocio(error: unknown, generico: string): string {
  if (error instanceof ErrorApi) {
    if (error.detail && [403, 409, 422].includes(error.status)) return error.detail;
    if (error.status === 503) return "Servicio no disponible; reintenta.";
  }
  return generico;
}

// Código estable del error (p. ej. «consentimiento_desactualizado») si el backend lo manda. Es la
// forma preferida de reconocer un caso; el texto del detail es sólo respaldo para backends anteriores.
export function codigoDe(error: unknown): string | null {
  if (!(error instanceof ErrorApi)) return null;
  const codigo = error.cuerpo?.codigo;
  return typeof codigo === "string" && codigo.length > 0 ? codigo : null;
}

// USO RESTRINGIDO: `mensajeDeNegocio` sólo es seguro con rutas del módulo de terminales, cuyos
// 403/409/422 traen mensajes FIJOS. NO usarlo con rutas de otros módulos (ausencias, días, ...)
// hasta que backend confirme que sus 422 ya no devuelven texto crudo. Una prueba
// (`mensajeDeNegocio.uso.test.ts`) falla si otro archivo lo importa.
