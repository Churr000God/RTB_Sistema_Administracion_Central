type ErrorAuthInfo = { name?: string; code?: string; status?: number; message?: string };

// Mapa cerrado: sólo códigos verificados como existentes en el error-codes.d.ts de
// @supabase/auth-js 2.114.0 (versión realmente instalada — el package.json pide ^2.45.0).
const MENSAJES: Record<string, string> = {
  insufficient_aal:
    "Por seguridad, confirmá el código de tu app autenticadora antes de cambiar la contraseña.",
  same_password: "La contraseña nueva tiene que ser distinta de la actual.",
  weak_password: "La contraseña es demasiado débil para las políticas del proyecto.",
  session_expired: "Tu enlace expiró o la sesión se cerró. Pedí uno nuevo.",
  session_not_found: "Tu enlace expiró o la sesión se cerró. Pedí uno nuevo.",
  otp_expired: "Este enlace venció. Solicitá uno nuevo.",
  reauthentication_needed: "Supabase pide reautenticación para este cambio.",
  over_request_rate_limit: "Demasiados intentos. Esperá unos minutos.",
  over_email_send_rate_limit:
    "Ya te enviamos un enlace hace un momento. Esperá unos segundos antes de pedir otro.",
};

/**
 * Log completo a consola: nunca se descarta un error de Supabase Auth sin dejar rastro.
 * error.message SÍ va acá (diagnóstico), pero nunca en la UI — puede cambiar entre
 * versiones de auth-js o filtrar detalle interno que no es para el usuario final.
 */
export function registrarErrorAuth(contexto: string, error: unknown): void {
  const info = error as ErrorAuthInfo | null;
  console.error(contexto, {
    name: info?.name,
    code: info?.code,
    status: info?.status,
    message: info?.message,
  });
}

/** Mensaje amigable en español. Diccionario cerrado — decisión de security: nunca mostrar
 * error.message crudo; un código fuera del mapa cae al mensaje por defecto que recibe el
 * llamador (la UI se encarga de mostrar el código técnico aparte, en un <small>). */
export function mensajeDeErrorAuth(error: unknown, porDefecto: string): string {
  const info = error as ErrorAuthInfo | null;
  const codigo = info?.code;
  if (codigo && MENSAJES[codigo]) {
    return MENSAJES[codigo];
  }
  if (!codigo && info?.status === 429) {
    return MENSAJES.over_request_rate_limit;
  }
  return porDefecto;
}

export function esInsuficienteAal(error: unknown): boolean {
  return (error as ErrorAuthInfo | null)?.code === "insufficient_aal";
}
