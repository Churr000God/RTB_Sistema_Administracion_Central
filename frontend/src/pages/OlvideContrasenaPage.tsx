import { type FormEvent, useState } from "react";
import { AlertCircle, Clock, KeyRound, Mail, Send } from "lucide-react";

import { AuthLayout } from "../layouts/AuthLayout";
import { supabase } from "../lib/supabaseClient";
import { mensajeDeErrorAuth, registrarErrorAuth } from "../lib/erroresAuth";
import { CONTACTOS } from "../lib/contactos";

export function OlvideContrasenaPage() {
  const [enviado, setEnviado] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    const correo = String(new FormData(evento.currentTarget).get("correo"));
    const { error: errorEnvio } = await supabase.auth.resetPasswordForEmail(correo, {
      redirectTo: `${window.location.origin}/restablecer-contrasena`,
    });
    if (errorEnvio) {
      registrarErrorAuth("OlvideContrasenaPage.resetPasswordForEmail", errorEnvio);
      setError(mensajeDeErrorAuth(errorEnvio, "No se pudo enviar el enlace. Intentá de nuevo."));
      return;
    }
    setError(null);
    setEnviado(true);
  }

  return (
    <AuthLayout titulo="Recupera tu acceso" bajada="Te enviamos un enlace a tu correo.">
      <span className="icono-tarjeta">
        <KeyRound size={22} aria-hidden="true" />
      </span>
      <h2>¿Olvidaste tu contraseña?</h2>
      {enviado ? (
        <p>Revisa tu correo para continuar.</p>
      ) : (
        <>
          <p>Escribe tu correo corporativo y te enviaremos un enlace para crear una nueva.</p>
          {error && (
            <div className="tarjeta-error" role="alert">
              <strong>
                <AlertCircle size={16} aria-hidden="true" />
                No se pudo enviar el enlace
              </strong>
              <p>{error}</p>
            </div>
          )}
          <form onSubmit={handleSubmit}>
            <label htmlFor="correo">Correo electrónico</label>
            <div className="campo-con-icono">
              <Mail size={16} className="icono-campo" aria-hidden="true" />
              <input
                id="correo"
                name="correo"
                type="email"
                placeholder="nombre@distribuidoracentral.mx"
                required
              />
            </div>
            <button type="submit" className="boton-con-icono">
              Enviar enlace de recuperación
              <Send size={16} aria-hidden="true" />
            </button>
            <p className="tarjeta-info">
              <Clock size={16} aria-hidden="true" />
              El enlace caduca en 30 minutos y sólo puede usarse una vez.
            </p>
          </form>
          <p className="texto-ayuda">
            ¿No recibes el correo? Revisa tu bandeja de no deseados o escribe a{" "}
            <a href={`mailto:${CONTACTOS.rh.correo}`}>Recursos Humanos</a>.
          </p>
        </>
      )}
    </AuthLayout>
  );
}
