import { type FormEvent, useEffect, useMemo, useRef, useState } from "react";
import {
  AlertCircle,
  ArrowRight,
  Check,
  CheckCircle2,
  Circle,
  Eye,
  EyeOff,
  Loader2,
  Lock,
  ShieldAlert,
  ShieldCheck,
} from "lucide-react";

import { AuthLayout } from "../layouts/AuthLayout";
import { Button } from "../components/Button";
import { supabase } from "../lib/supabaseClient";
import { obtenerFactorTotpVerificado, verificarTotp } from "../lib/mfa";
import { esInsuficienteAal, mensajeDeErrorAuth, registrarErrorAuth } from "../lib/erroresAuth";
import { CasilleroCodigo } from "../components/CasilleroCodigo";
import { TemporizadorTotp } from "../components/TemporizadorTotp";

function leerErrorDelEnlace(): string | null {
  if (typeof window === "undefined") return null;
  const hash = new URLSearchParams(window.location.hash.replace(/^#/, ""));
  const codigo = hash.get("error_code");
  if (codigo === "otp_expired") {
    return "Este enlace venció. Solicitá uno nuevo.";
  }
  if (hash.get("error")) {
    return "Este enlace ya no es válido. Solicitá uno nuevo.";
  }
  return null;
}

const REQUISITOS = [
  { clave: "longitud", texto: "Al menos 12 caracteres", cumple: (v: string) => v.length >= 12 },
  {
    clave: "mayus",
    texto: "Una mayúscula y una minúscula",
    cumple: (v: string) => /[a-z]/.test(v) && /[A-Z]/.test(v),
  },
  {
    clave: "numero",
    texto: "Un número o símbolo",
    cumple: (v: string) => /[0-9]/.test(v) || /[^A-Za-z0-9]/.test(v),
  },
];

type Estado = "cargando" | "necesita-totp" | "listo" | "guardado";

type Props = {
  modo?: "restablecer" | "invitacion";
};

const DESCRIPCION_TEMPORIZADOR_ID = "temporizador-totp-descripcion-restablecer";

export function RestablecerContrasenaPage({ modo = "restablecer" }: Props) {
  const [errorEnlace] = useState<string | null>(leerErrorDelEnlace);
  const [estado, setEstado] = useState<Estado>("cargando");
  const [factorId, setFactorId] = useState<string | null>(null);

  const [codigoTotp, setCodigoTotp] = useState("");
  const [errorTotp, setErrorTotp] = useState<string | null>(null);
  const [enviandoTotp, setEnviandoTotp] = useState(false);
  const [intentoTotp, setIntentoTotp] = useState(0);

  const [error, setError] = useState<string | null>(null);
  const [errorCodigo, setErrorCodigo] = useState<string | null>(null);
  const [mostrarNueva, setMostrarNueva] = useState(false);
  const [mostrarConfirmar, setMostrarConfirmar] = useState(false);
  const [nuevaValor, setNuevaValor] = useState("");
  const [guardando, setGuardando] = useState(false);

  const vivoRef = useRef(true);

  useEffect(() => {
    if (errorEnlace) return; // el hash ya cortó: no hace falta tocar Supabase

    vivoRef.current = true;

    async function evaluarAal() {
      // Con detectSessionInUrl:true la sesión del hash se establece de forma asíncrona — un
      // getSession() explícito espera a que el SDK termine antes de leer el AAL del JWT.
      await supabase.auth.getSession();
      const [{ data: aal }, factor] = await Promise.all([
        supabase.auth.mfa.getAuthenticatorAssuranceLevel(),
        obtenerFactorTotpVerificado(),
      ]);
      if (!vivoRef.current) return;
      setFactorId(factor?.id ?? null);
      if (factor && aal?.currentLevel === "aal1" && aal?.nextLevel === "aal2") {
        setEstado("necesita-totp");
      } else {
        setEstado("listo");
      }
    }

    const { data: suscripcion } = supabase.auth.onAuthStateChange((evento) => {
      if (evento === "PASSWORD_RECOVERY" || evento === "SIGNED_IN" || evento === "INITIAL_SESSION") {
        // No await-ear llamadas de Supabase dentro del callback de onAuthStateChange: es un
        // deadlock documentado del SDK. Se envuelve en setTimeout(…, 0) para salir del callback.
        setTimeout(() => {
          if (vivoRef.current) evaluarAal();
        }, 0);
      }
    });

    evaluarAal(); // por si el evento ya disparó antes de que este efecto se suscribiera

    return () => {
      vivoRef.current = false;
      suscripcion.subscription.unsubscribe();
    };
  }, [errorEnlace]);

  const cumplidos = useMemo(
    () => REQUISITOS.map((requisito) => requisito.cumple(nuevaValor)),
    [nuevaValor]
  );
  const totalCumplidos = cumplidos.filter(Boolean).length;
  const fuerza =
    totalCumplidos === REQUISITOS.length ? "fuerte" : totalCumplidos >= 1 ? "media" : "debil";
  const etiquetaFuerza = { debil: "Débil", media: "Media", fuerte: "Fuerte" }[fuerza];

  async function handleSubmitTotp(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    if (!factorId || codigoTotp.length < 6 || enviandoTotp) return;
    setEnviandoTotp(true);
    const { error: errorVerificar } = await verificarTotp(factorId, codigoTotp);
    setEnviandoTotp(false);
    if (errorVerificar) {
      registrarErrorAuth("RestablecerContrasenaPage.confirmarTotp", errorVerificar);
      setErrorTotp(mensajeDeErrorAuth(errorVerificar, "No se pudo verificar el código."));
      setCodigoTotp("");
      setIntentoTotp((n) => n + 1);
      return;
    }
    // mfa.verify eleva la sesión a aal2 in situ (el SDK reemplaza el token) — ningún redirect,
    // ningún link consumido de nuevo.
    setEstado("listo");
  }

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    const formulario = new FormData(evento.currentTarget);
    const nueva = String(formulario.get("nueva"));
    const confirmar = String(formulario.get("confirmar"));
    if (nueva !== confirmar) {
      setError("Las contraseñas no coinciden.");
      setErrorCodigo(null);
      return;
    }
    if (totalCumplidos < REQUISITOS.length) {
      setError("La contraseña no cumple los requisitos de seguridad.");
      setErrorCodigo(null);
      return;
    }
    setGuardando(true);
    const { error: errorUpdate } = await supabase.auth.updateUser({ password: nueva });
    if (errorUpdate) {
      registrarErrorAuth("RestablecerContrasenaPage.updateUser", errorUpdate);
      if (esInsuficienteAal(errorUpdate)) {
        // Red de seguridad: aunque la detección del montaje haya fallado (factor recién
        // enrolado, JWT sin el claim todavía), acá se resuelve el factorId igual antes de
        // mandar al usuario al paso TOTP, en vez de dejarlo en un callejón sin salida.
        if (!factorId) {
          const factor = await obtenerFactorTotpVerificado();
          setFactorId(factor?.id ?? null);
        }
        setGuardando(false);
        setEstado("necesita-totp");
        return;
      }
      setGuardando(false);
      setError(mensajeDeErrorAuth(errorUpdate, "No se pudo actualizar la contraseña."));
      setErrorCodigo((errorUpdate as { code?: string } | null)?.code ?? null);
      return;
    }

    const { error: errorSignOutOtros } = await supabase.auth.signOut({ scope: "others" });
    if (errorSignOutOtros) {
      registrarErrorAuth("RestablecerContrasenaPage.signOut(others)", errorSignOutOtros);
      // La contraseña ya cambió — no bloquear la UX por esto, sólo queda el log para diagnóstico.
    }
    setGuardando(false);
    setEstado("guardado");
  }

  if (errorEnlace) {
    return (
      <AuthLayout titulo="Define tu nueva contraseña" bajada="">
        <p role="alert">{errorEnlace}</p>
        <a href="/olvide-contrasena">Solicitar un enlace nuevo</a>
      </AuthLayout>
    );
  }

  if (estado === "guardado") {
    return (
      <AuthLayout titulo="Contraseña actualizada" bajada="Ya puedes iniciar sesión.">
        <a href={modo === "invitacion" ? "/configurar-2fa" : "/"}>
          {modo === "invitacion" ? "Configurar verificación en dos pasos" : "Ir a iniciar sesión"}
        </a>
      </AuthLayout>
    );
  }

  const tituloPanel = modo === "invitacion" ? "Crea tu contraseña" : "Define tu nueva contraseña";

  return (
    <AuthLayout titulo={tituloPanel} bajada="">
      {estado === "cargando" && (
        <span className="insignia insignia--neutra insignia--bloque">
          <Loader2 size={14} className="icono-girando" aria-hidden="true" />
          Comprobando el enlace…
        </span>
      )}
      {estado === "necesita-totp" && (
        <span className="insignia insignia--aviso insignia--bloque">
          <ShieldAlert size={14} aria-hidden="true" />
          Falta confirmar el segundo paso
        </span>
      )}
      {estado === "listo" && (
        <span className="insignia insignia--exito insignia--bloque">
          <ShieldCheck size={14} aria-hidden="true" />
          Enlace verificado
        </span>
      )}

      {estado === "necesita-totp" && (
        <>
          <h2>Verificación en dos pasos</h2>
          <p>Antes de {modo === "invitacion" ? "crear" : "cambiar"} tu contraseña, confirmá el código de tu app autenticadora.</p>
          <form onSubmit={handleSubmitTotp}>
            <CasilleroCodigo
              key={intentoTotp}
              valor={codigoTotp}
              onCambio={setCodigoTotp}
              etiqueta="Código de verificación"
              idBase="totp-restablecer"
              name="codigo"
              descripcionId={DESCRIPCION_TEMPORIZADOR_ID}
              invalido={Boolean(errorTotp)}
              deshabilitado={enviandoTotp}
              enfocarAlMontar
            />
            <TemporizadorTotp id={DESCRIPCION_TEMPORIZADOR_ID} />
            {errorTotp && (
              <div className="tarjeta-error" role="alert">
                <strong>
                  <AlertCircle size={16} aria-hidden="true" />
                  Código incorrecto
                </strong>
                <p>{errorTotp}</p>
              </div>
            )}
            <Button
              type="submit"
              icono={ArrowRight}
              disabled={codigoTotp.length < 6}
              cargando={enviandoTotp}
              textoCargando="Verificando…"
            >
              Confirmar código
            </Button>
          </form>
        </>
      )}

      {estado === "listo" && (
        <>
          <h2>{modo === "invitacion" ? "Crea tu contraseña" : "Restablece tu contraseña"}</h2>
          <p>Define la nueva contraseña de tu cuenta corporativa y confírmala para guardarla.</p>
          <form onSubmit={handleSubmit}>
            <label htmlFor="nueva">Nueva contraseña</label>
            <div className="campo-con-icono">
              <Lock size={16} className="icono-campo" aria-hidden="true" />
              <input
                id="nueva"
                name="nueva"
                type={mostrarNueva ? "text" : "password"}
                required
                minLength={12}
                value={nuevaValor}
                onChange={(evento) => setNuevaValor(evento.target.value)}
              />
              <button
                type="button"
                className="boton-ojo"
                onClick={() => setMostrarNueva((v) => !v)}
                aria-label={mostrarNueva ? "Ocultar contraseña" : "Mostrar contraseña"}
              >
                {mostrarNueva ? <EyeOff size={16} /> : <Eye size={16} />}
              </button>
            </div>
            {nuevaValor && (
              <div className="medidor-fuerza">
                <div className="barras">
                  {REQUISITOS.map((requisito, indice) => (
                    <span
                      key={requisito.clave}
                      className={`barra ${indice < totalCumplidos ? `activa-${fuerza}` : ""}`}
                    />
                  ))}
                </div>
                <div className="etiqueta">
                  <span>Seguridad de la contraseña</span>
                  <strong>{etiquetaFuerza}</strong>
                </div>
              </div>
            )}
            <label htmlFor="confirmar">Confirmar contraseña</label>
            <div className="campo-con-icono">
              <Lock size={16} className="icono-campo" aria-hidden="true" />
              <input
                id="confirmar"
                name="confirmar"
                type={mostrarConfirmar ? "text" : "password"}
                required
                minLength={12}
              />
              <button
                type="button"
                className="boton-ojo"
                onClick={() => setMostrarConfirmar((v) => !v)}
                aria-label={mostrarConfirmar ? "Ocultar contraseña" : "Mostrar contraseña"}
              >
                {mostrarConfirmar ? <EyeOff size={16} /> : <Eye size={16} />}
              </button>
            </div>
            <ul className="lista-requisitos">
              {REQUISITOS.map((requisito, indice) => (
                <li key={requisito.clave} className={cumplidos[indice] ? "cumplido" : ""}>
                  {cumplidos[indice] ? (
                    <CheckCircle2 size={16} aria-hidden="true" />
                  ) : (
                    <Circle size={16} aria-hidden="true" />
                  )}
                  {requisito.texto}
                </li>
              ))}
            </ul>
            {error && (
              <p role="alert">
                {error}
                {errorCodigo && (
                  <>
                    {" "}
                    <small>(código: {errorCodigo})</small>
                  </>
                )}
              </p>
            )}
            <Button type="submit" icono={Check} cargando={guardando} textoCargando="Guardando…">
              Guardar contraseña
            </Button>
          </form>
          <p className="texto-ayuda">
            Al guardar se cerrarán todas tus sesiones activas y deberás iniciar sesión de nuevo.
          </p>
        </>
      )}
    </AuthLayout>
  );
}
