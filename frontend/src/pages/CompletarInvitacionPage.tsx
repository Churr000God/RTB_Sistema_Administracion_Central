import { RestablecerContrasenaPage } from "./RestablecerContrasenaPage";

export function CompletarInvitacionPage() {
  // Mismo formulario que restablecer contraseña — Supabase ya autenticó a la persona vía el link
  // de invitación antes de llegar aquí (mismo mecanismo, distinto punto de entrada). modo=
  // "invitacion" cambia el copy y, tras guardar, manda a /configurar-2fa en vez de /. Un
  // invitado nuevo no tiene factor TOTP → nextLevel="aal1" → el paso TOTP embebido no se activa.
  return <RestablecerContrasenaPage modo="invitacion" />;
}
