import { useEffect, useState } from "react";
import { AlertCircle, Loader2, ShieldOff } from "lucide-react";

import { AuthLayout } from "../layouts/AuthLayout";
import { supabase } from "../lib/supabaseClient";
import { VerificarTotpPage } from "./VerificarTotpPage";

type Estado = "cargando" | "listo" | "sin-factor" | "error";

/**
 * Ruta /verificar-totp para logins siguientes (no el enrolamiento — ese ya trae su propio
 * factorId de Configurar2FAPage). Busca el factor TOTP ya verificado de la sesión actual.
 */
export function VerificarTotpRoute() {
  const [estado, setEstado] = useState<Estado>("cargando");
  const [factorId, setFactorId] = useState<string | null>(null);

  useEffect(() => {
    let vivo = true;
    supabase.auth.mfa.listFactors().then(({ data, error }) => {
      if (!vivo) return;
      if (error) {
        console.error("VerificarTotpRoute.listFactors", error);
        setEstado("error");
        return;
      }
      const factor = data?.totp.find((f) => f.status === "verified");
      if (!factor) {
        setEstado("sin-factor");
        return;
      }
      setFactorId(factor.id);
      setEstado("listo");
    });
    return () => {
      vivo = false;
    };
  }, []);

  if (estado === "cargando") {
    return (
      <AuthLayout titulo="Verifica tu identidad" bajada="">
        <p className="boton-con-icono">
          <Loader2 size={16} className="icono-girando" aria-hidden="true" />
          Cargando…
        </p>
      </AuthLayout>
    );
  }

  if (estado === "sin-factor") {
    return (
      <AuthLayout titulo="Verifica tu identidad" bajada="">
        <div className="tarjeta-error" role="alert">
          <strong>
            <ShieldOff size={16} aria-hidden="true" />
            Sin verificación en dos pasos
          </strong>
          <p>Tu cuenta no tiene un método de verificación configurado todavía.</p>
        </div>
        <a href="/configurar-2fa" className="boton-con-icono">
          Configurar verificación en dos pasos
        </a>
      </AuthLayout>
    );
  }

  if (estado === "error") {
    return (
      <AuthLayout titulo="Verifica tu identidad" bajada="">
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            No se pudo comprobar tu verificación
          </strong>
          <p>Ocurrió un problema de conexión. Intentá de nuevo en unos segundos.</p>
        </div>
      </AuthLayout>
    );
  }

  return <VerificarTotpPage factorId={factorId as string} />;
}
