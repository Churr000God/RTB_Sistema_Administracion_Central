import { createClient } from "@supabase/supabase-js";

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL as string;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string;

// Opciones explícitas — antes quedaban en los defaults implícitos de auth-js. Documentación
// ejecutable: la próxima sesión que investigue un bug de recovery/invitación no tiene que ir a
// leer el código fuente de auth-js para descartar un mismatch de flujo PKCE vs. implícito.
export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    // Los links de recovery/invitación de Supabase llegan con el token en el hash de la URL
    // (#access_token=...), no como ?code=... — ese es el flujo "implicit", no "pkce".
    flowType: "implicit",
    // Con flowType implicit, detectSessionInUrl es lo que efectivamente lee ese hash al cargar
    // la página y establece la sesión — si se apagara, RestablecerContrasenaPage nunca vería sesión.
    detectSessionInUrl: true,
    persistSession: true,
    autoRefreshToken: true,
  },
});
