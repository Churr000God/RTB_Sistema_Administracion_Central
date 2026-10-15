import { apiFetch } from "./apiClient";

export type SesionOut = {
  auth_user_id: string;
  correo: string | null;
  nombre_usuario: string | null;
  persona_id: string | null;
  persona_estado: string | null;
  acceso_permitido: boolean;
  motivo_bloqueo: string | null;
  puede_ver_modulo_1: boolean;
  puede_ver_modulo_2: boolean;
  puede_ver_modulo_3: boolean;
  // Sólo comodidad de UI: la autorización real es fn_excepcion_dia_cerrado_descartar.
  puede_descartar_excepciones?: boolean;
  // Módulo Terminales (contrato §7). Opcionales: un backend anterior no las manda.
  puede_ver_terminales?: boolean;
  puede_editar_terminales?: boolean;
  puede_editar_config_terminales?: boolean;
};

// Falla de GET /api/sesion. `status` es el HTTP (401 = sin sesión) o null si fue de red / tiempo agotado.
export class ErrorSesion extends Error {
  status: number | null;
  // Espera pedida por el servidor (cabecera Retry-After, en ms), ya acotada; null si no la mandó.
  esperaMs: number | null;

  constructor(status: number | null, esperaMs: number | null = null) {
    super(status === null ? "GET /api/sesion sin respuesta" : `GET /api/sesion respondió ${status}`);
    this.name = "ErrorSesion";
    this.status = status;
    this.esperaMs = esperaMs;
  }
}

// Sólo una falla de red/tiempo o un 5xx merece reintento automático: un 4xx (401, 403) no cambia solo.
export function esReintentable(error: unknown): boolean {
  return error instanceof ErrorSesion && (error.status === null || error.status >= 500);
}

const TIEMPO_MAXIMO_MS = 10_000;

// Tope de lo que se acata de Retry-After: la pantalla no debe quedarse esperando más que esto.
const ESPERA_MAXIMA_MS = 5_000;

// Retry-After en segundos (la forma que manda el backend); una fecha HTTP u otro valor se ignora.
function esperaDe(respuesta: Response): number | null {
  const bruto = respuesta.headers.get("Retry-After");
  if (bruto === null || !/^\d+$/.test(bruto.trim())) return null;
  return Math.min(Number(bruto.trim()) * 1000, ESPERA_MAXIMA_MS);
}

// Pausas entre los intentos automáticos (2 reintentos, 3 intentos en total). En pruebas sin pausa.
let pausasDeReintento: number[] = import.meta.env.MODE === "test" ? [0, 0] : [500, 1500];

export function configurarPausasDeReintento(pausas: number[]): void {
  pausasDeReintento = pausas;
}

let sesionEnVuelo: Promise<SesionOut> | null = null;
let sesionConReintentoEnVuelo: Promise<SesionOut> | null = null;

async function pedirSesion(): Promise<SesionOut> {
  let temporizador: ReturnType<typeof setTimeout> | undefined;
  // Sin AbortController a propósito: apiFetch("/api/sesion") conserva su firma; el tiempo agotado sólo deja
  // de esperar la respuesta (la petición tardía se descarta).
  const agotado = new Promise<never>((_, rechazar) => {
    temporizador = setTimeout(() => rechazar(new ErrorSesion(null)), TIEMPO_MAXIMO_MS);
  });
  const consulta = (async () => {
    const respuesta = await apiFetch("/api/sesion");
    if (!respuesta.ok) throw new ErrorSesion(respuesta.status, esperaDe(respuesta));
    try {
      return (await respuesta.json()) as SesionOut;
    } catch {
      throw new ErrorSesion(null);
    }
  })();
  // Evita un «unhandled rejection» si la consulta falla después de haberse agotado el tiempo.
  consulta.catch(() => undefined);
  try {
    return await Promise.race([consulta, agotado]);
  } catch (error) {
    if (error instanceof ErrorSesion) throw error;
    throw new ErrorSesion(null);
  } finally {
    clearTimeout(temporizador);
  }
}

/**
 * Deduplica GET /api/sesion a nivel de módulo. Causa raíz real del bug donde el guard de
 * AppShell (y la bifurcación de LoginPage) fallaban de forma no determinística: en dev,
 * React.StrictMode monta el efecto dos veces, disparando dos GET /api/sesion concurrentes.
 * Por timing entre apiFetch (que lee el token con supabase.auth.getSession() en cada llamada)
 * y el doble montaje, una de las dos peticiones podía salir sin token válido (422) — el
 * fail-open de D8 entraba correctamente PARA ESA petición puntual, pero disparaba de más por
 * la carrera, no por una falla real. Dos invocaciones concurrentes de consultarSesion() ahora
 * comparten el mismo fetch en vuelo en vez de generar una segunda petición.
 *
 * Sin reintentos: lo usa el login, que sigue siendo fail-open (es sólo UX).
 */
export function consultarSesion(): Promise<SesionOut> {
  if (!sesionEnVuelo) {
    sesionEnVuelo = pedirSesion().finally(() => {
      sesionEnVuelo = null;
    });
  }
  return sesionEnVuelo;
}

/**
 * La que usa el AppShell y todo lo que decide qué mostrar: reintenta con una pausa corta ante una falla
 * de red o un 5xx (un statement timeout puntual de la base no debe abrir ni cerrar la app), y falla
 * recién tras el último intento. También deduplica en vuelo, reintentos incluidos.
 */
export function consultarSesionConReintento(): Promise<SesionOut> {
  if (!sesionConReintentoEnVuelo) {
    sesionConReintentoEnVuelo = (async () => {
      let ultimo: unknown;
      for (let intento = 0; intento <= pausasDeReintento.length; intento += 1) {
        try {
          return await pedirSesion();
        } catch (error) {
          ultimo = error;
          if (!esReintentable(error) || intento === pausasDeReintento.length) break;
          // Se espera lo que pida el servidor (Retry-After) o, si no, la pausa corta; nunca menos que esa pausa.
          const pedida = error instanceof ErrorSesion ? error.esperaMs : null;
          await new Promise((resolver) => setTimeout(resolver, Math.max(pausasDeReintento[intento], pedida ?? 0)));
        }
      }
      throw ultimo;
    })().finally(() => {
      sesionConReintentoEnVuelo = null;
    });
  }
  return sesionConReintentoEnVuelo;
}
