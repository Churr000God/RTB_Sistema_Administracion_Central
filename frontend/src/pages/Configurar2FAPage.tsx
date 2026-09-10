import { useEffect, useRef, useState } from "react";
import { AlertCircle, ArrowRight, Loader2, ShieldCheck } from "lucide-react";

import { AuthLayout } from "../layouts/AuthLayout";
import { supabase } from "../lib/supabaseClient";
import { registrarErrorAuth } from "../lib/erroresAuth";
import { Button } from "../components/Button";
import { VerificarTotpPage } from "./VerificarTotpPage";

const INSIGNIA_PASO = { icono: ShieldCheck, texto: "Paso 2 de 3 · Seguridad" };

const PASOS = [
  {
    titulo: "Descarga una app autenticadora",
    detalle: "Google Authenticator, Microsoft Authenticator o Authy.",
  },
  {
    titulo: "Escanea el código QR",
    detalle: "Abre la app, elige «Agregar cuenta» y apunta la cámara.",
  },
  {
    titulo: "Ingresa el código de 6 dígitos",
    detalle: "La app genera un código nuevo cada 30 segundos.",
  },
];

export function Configurar2FAPage() {
  const [qr, setQr] = useState<string | null>(null);
  const [claveManual, setClaveManual] = useState<string | null>(null);
  const [factorId, setFactorId] = useState<string | null>(null);
  const [listoParaVerificar, setListoParaVerificar] = useState(false);
  const [yaConfigurado, setYaConfigurado] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const yaEjecutado = useRef(false);

  useEffect(() => {
    // Guard contra el doble-montaje de efectos de React.StrictMode en dev: enroll() no es
    // idempotente (crea un factor TOTP nuevo cada vez) — sin este guard, el segundo montaje
    // volvía a llamar enroll() antes de que el primer factor quedara verificado y Supabase
    // respondía 422 mfa_factor_name_conflict. Mismo problema que ya se resolvió en
    // lib/sesion.ts (consultarSesion), pero acá basta un guard por componente: sólo hay un
    // consumidor de este efecto, no hace falta deduplicar a nivel de módulo.
    if (yaEjecutado.current) return;
    yaEjecutado.current = true;

    supabase.auth.mfa.listFactors().then(({ data, error: errorListado }) => {
      if (errorListado) {
        registrarErrorAuth("Configurar2FAPage.listFactors", errorListado);
        setError("No se pudo comprobar el estado de tu verificación en dos pasos.");
        return;
      }
      const yaTieneTotp = data?.totp.some((factor) => factor.status === "verified");
      if (yaTieneTotp) {
        setYaConfigurado(true);
        return;
      }
      supabase.auth.mfa.enroll({ factorType: "totp" }).then(({ data: enrolado, error: errorEnroll }) => {
        if (errorEnroll || !enrolado) {
          registrarErrorAuth("Configurar2FAPage.enroll", errorEnroll);
          setError("No se pudo generar el código. Intenta de nuevo.");
          return;
        }
        setQr(enrolado.totp.qr_code);
        setClaveManual(enrolado.totp.secret);
        setFactorId(enrolado.id);
      });
    });
  }, []);

  if (factorId && listoParaVerificar) {
    return (
      <VerificarTotpPage
        factorId={factorId}
        tituloPanel="Protege tu cuenta"
        bajadaPanel="Escanea el código con tu app autenticadora."
        insignia={INSIGNIA_PASO}
      />
    );
  }

  if (yaConfigurado) {
    return (
      <AuthLayout
        titulo="Protege tu cuenta"
        bajada="Escanea el código con tu app autenticadora."
        insignia={INSIGNIA_PASO}
      >
        <p className="tarjeta-info">
          <ShieldCheck size={16} aria-hidden="true" />
          Tu cuenta ya tiene la verificación en dos pasos activa.
        </p>
        <Button href="/personas" icono={ArrowRight} tamanoIcono={14}>
          Ir a Personas
        </Button>
      </AuthLayout>
    );
  }

  return (
    <AuthLayout
      titulo="Protege tu cuenta"
      bajada="Escanea el código con tu app autenticadora."
      insignia={INSIGNIA_PASO}
    >
      {error && (
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            No se pudo continuar
          </strong>
          <p>{error}</p>
        </div>
      )}
      {!error && (qr ? (
        <>
          <div className="icono-tarjeta">
            <ShieldCheck size={22} aria-hidden="true" />
          </div>
          <h2>Escanea el código con tu app</h2>
          <ol className="pasos-totp">
            {PASOS.map((paso, indice) => (
              <li key={paso.titulo}>
                <span className="numero-paso" aria-hidden="true">
                  {indice + 1}
                </span>
                <span>
                  <strong>{paso.titulo}</strong>
                  <span className="detalle">{paso.detalle}</span>
                </span>
              </li>
            ))}
          </ol>
          <img src={qr} alt="Código QR para configurar 2FA" />
          {claveManual && (
            <p className="subtitulo-pagina">
              ¿No puedes escanear? Usa esta clave manual:{" "}
              <span className="pildora-monoespaciada">{claveManual}</span>
            </p>
          )}
          <Button onClick={() => setListoParaVerificar(true)} icono={ArrowRight}>
            Ya la agregué, continuar
          </Button>
        </>
      ) : (
        <p className="boton-con-icono">
          <Loader2 size={16} className="icono-girando" aria-hidden="true" />
          Generando código…
        </p>
      ))}
    </AuthLayout>
  );
}
