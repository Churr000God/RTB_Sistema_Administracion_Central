import { type FormEvent, useEffect, useState } from "react";
import { AlertCircle, ArrowLeft, ArrowRight, ShieldCheck } from "lucide-react";

import { AuthLayout } from "../layouts/AuthLayout";
import { Button } from "../components/Button";
import { supabase } from "../lib/supabaseClient";
import { verificarTotp } from "../lib/mfa";
import { registrarErrorAuth } from "../lib/erroresAuth";
import { CasilleroCodigo } from "../components/CasilleroCodigo";
import { TemporizadorTotp } from "../components/TemporizadorTotp";

type Insignia = { icono: typeof ShieldCheck; texto: string };

type Props = {
  factorId: string;
  tituloPanel?: string;
  bajadaPanel?: string;
  insignia?: Insignia;
  correo?: string;
};

const DESCRIPCION_TEMPORIZADOR_ID = "temporizador-totp-descripcion";

function mensajeErrorTotp(error: unknown): string {
  const codigo = (error as { code?: string } | null)?.code;
  const status = (error as { status?: number } | null)?.status;
  if (codigo === "mfa_challenge_expired") {
    return "El código expiró antes de verificarse. Ingresá uno nuevo.";
  }
  if (status === 429 || codigo === "over_request_rate_limit") {
    return "Demasiados intentos. Esperá unos minutos antes de volver a intentar.";
  }
  if (codigo === "mfa_verification_failed") {
    return "El código no coincide. Verificá los 6 dígitos e intentá de nuevo.";
  }
  return "No se pudo verificar el código. Intentá de nuevo.";
}

export function VerificarTotpPage({
  factorId,
  tituloPanel = "Verifica tu identidad",
  bajadaPanel = "Un paso más para proteger tu jornada.",
  insignia,
  correo: correoProp,
}: Props) {
  const [codigo, setCodigo] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);
  const [intento, setIntento] = useState(0);
  const [correo, setCorreo] = useState<string | null>(correoProp ?? null);

  useEffect(() => {
    if (correoProp) return;
    supabase.auth.getSession().then(({ data }) => {
      setCorreo(data.session?.user.email ?? null);
    });
  }, [correoProp]);

  async function cambiarCuenta() {
    await supabase.auth.signOut();
    window.location.href = "/";
  }

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    if (codigo.length < 6 || enviando) return;
    setEnviando(true);
    const { error: errorVerificar } = await verificarTotp(factorId, codigo);
    setEnviando(false);
    if (errorVerificar) {
      registrarErrorAuth("VerificarTotpPage.verificar", errorVerificar);
      setError(mensajeErrorTotp(errorVerificar));
      setCodigo("");
      setIntento((n) => n + 1);
      return;
    }
    window.location.href = "/personas";
  }

  return (
    <AuthLayout titulo={tituloPanel} bajada={bajadaPanel} insignia={insignia}>
      <div className="icono-tarjeta">
        <ShieldCheck size={22} aria-hidden="true" />
      </div>
      <h2>Verificación en dos pasos</h2>
      <p>Abre tu app autenticadora e ingresa el código de 6 dígitos que aparece para Kairos.</p>
      {correo && (
        <span className="chip-correo">
          <span className="correo">{correo}</span>
          <button type="button" onClick={cambiarCuenta}>
            Cambiar
          </button>
        </span>
      )}
      <form onSubmit={handleSubmit}>
        <CasilleroCodigo
          key={intento}
          valor={codigo}
          onCambio={setCodigo}
          etiqueta="Código de verificación"
          idBase="totp"
          name="codigo"
          descripcionId={DESCRIPCION_TEMPORIZADOR_ID}
          invalido={Boolean(error)}
          deshabilitado={enviando}
          enfocarAlMontar
        />
        <TemporizadorTotp id={DESCRIPCION_TEMPORIZADOR_ID} />
        {error && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              Código incorrecto
            </strong>
            <p>{error}</p>
          </div>
        )}
        <Button
          type="submit"
          icono={ArrowRight}
          disabled={codigo.length < 6}
          cargando={enviando}
          textoCargando="Verificando…"
        >
          Verificar
        </Button>
      </form>
      {/* "Usar un código de respaldo" — pendiente: Supabase MFA no soporta backup codes hoy. */}
      <a href="/" className="boton-con-icono" style={{ fontSize: "0.85rem" }}>
        <ArrowLeft size={14} aria-hidden="true" />
        Volver al inicio de sesión
      </a>
    </AuthLayout>
  );
}
