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
};

let sesionEnVuelo: Promise<SesionOut> | null = null;

/**
 * Deduplica GET /api/sesion a nivel de módulo. Causa raíz real del bug donde el guard de
 * AppShell (y la bifurcación de LoginPage) fallaban de forma no determinística: en dev,
 * React.StrictMode monta el efecto dos veces, disparando dos GET /api/sesion concurrentes.
 * Por timing entre apiFetch (que lee el token con supabase.auth.getSession() en cada llamada)
 * y el doble montaje, una de las dos peticiones podía salir sin token válido (422) — el
 * fail-open de D8 entraba correctamente PARA ESA petición puntual, pero disparaba de más por
 * la carrera, no por una falla real. Dos invocaciones concurrentes de consultarSesion() ahora
 * comparten el mismo fetch en vuelo en vez de generar una segunda petición.
 */
export function consultarSesion(): Promise<SesionOut> {
  if (!sesionEnVuelo) {
    sesionEnVuelo = apiFetch("/api/sesion")
      .then((respuesta) => {
        if (!respuesta.ok) {
          throw new Error(`GET /api/sesion respondió ${respuesta.status}`);
        }
        return respuesta.json();
      })
      .finally(() => {
        sesionEnVuelo = null;
      });
  }
  return sesionEnVuelo;
}
