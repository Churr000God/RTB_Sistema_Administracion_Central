import { type FormEvent, useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { AlertTriangle, CheckCircle2, Info, RotateCcw, ShieldAlert, UserX } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { irA } from "../lib/navegacion";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";

type Persona = {
  id: string;
  primer_nombre: string;
  apellido_paterno: string;
  estado: string;
};

const ETIQUETA_ESTADO: Record<string, string> = {
  activo: "Activa",
  suspension: "Suspendida",
  baja_definitiva: "Baja definitiva",
};

const TITULO_RESULTADO: Record<string, string> = {
  suspension: "Suspensión registrada",
  baja_definitiva: "Baja definitiva registrada",
  reactivacion: "Reactivación registrada",
};

type Resultado = { tipo: string; advertencias: string[]; bajasTerminal: number };

async function mensajeDeError(respuesta: Response, generico: string): Promise<string> {
  try {
    const cuerpo = await respuesta.json();
    if (typeof cuerpo?.detail === "string") return cuerpo.detail;
  } catch {
    // cuerpo no era JSON legible — cae al genérico
  }
  return generico;
}

export function CambiarEstadoPage() {
  const { id } = useParams<{ id: string }>();
  const [error, setError] = useState<string | null>(null);
  const [persona, setPersona] = useState<Persona | null>(null);
  const [enviando, setEnviando] = useState(false);
  const [resultado, setResultado] = useState<Resultado | null>(null);

  useEffect(() => {
    apiFetch(`/api/personas/${id}`)
      .then((r) => r.json())
      .then(setPersona)
      .catch(() => undefined);
  }, [id]);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    setEnviando(true);
    const f = new FormData(evento.currentTarget);
    const respuesta = await apiFetch(`/api/personas/${id}/movimientos`, {
      method: "POST",
      body: JSON.stringify({
        tipo_movimiento: f.get("tipo_movimiento"),
        motivo: f.get("motivo"),
      }),
    });
    if (!respuesta.ok) {
      setError(await mensajeDeError(respuesta, "No se pudo registrar el movimiento."));
      setEnviando(false);
      return;
    }
    // El movimiento YA está guardado. Si backend avisa de algo sobre la baja en terminal (el hook de
    // SCJ-DEC-12 §5 falló y el job lo reintentará), no se redirige a ciegas: se muestra el aviso.
    let cuerpo: { advertencias?: unknown; bajas_terminal_emitidas?: unknown } | null = null;
    try {
      cuerpo = await respuesta.json();
    } catch {
      // cuerpo no legible: el movimiento ya se guardó, se sigue como siempre
    }
    const advertencias = Array.isArray(cuerpo?.advertencias)
      ? cuerpo.advertencias.filter((a): a is string => typeof a === "string")
      : [];
    const bajasTerminal = typeof cuerpo?.bajas_terminal_emitidas === "number" ? cuerpo.bajas_terminal_emitidas : 0;
    if (advertencias.length === 0 && bajasTerminal <= 0) {
      irA(`/personas/${id}`);
      return;
    }
    setResultado({ tipo: String(f.get("tipo_movimiento") ?? ""), advertencias, bajasTerminal });
    setEnviando(false);
  }

  const nombreCompleto =
    persona?.primer_nombre && persona?.apellido_paterno
      ? `${persona.primer_nombre} ${persona.apellido_paterno}`
      : null;
  const iniciales = nombreCompleto
    ? `${persona!.primer_nombre[0]}${persona!.apellido_paterno[0]}`.toUpperCase()
    : "";

  if (resultado) {
    const pendiente = resultado.advertencias.includes("baja_terminal_pendiente");
    const desconocidas = resultado.advertencias.some((a) => a !== "baja_terminal_pendiente");
    return (
      <AppShell>
        <div className="contenedor-pagina">
          <nav className="migas">
            <a href="/personas">Personas</a> / <strong>Cambio de estado</strong>
          </nav>
          <div className="tarjeta-resumen">
            <h2 className="boton-con-icono" style={{ justifyContent: "flex-start", fontSize: "1.2rem" }}>
              <CheckCircle2 size={22} aria-hidden="true" /> {TITULO_RESULTADO[resultado.tipo] ?? "Movimiento registrado"}
            </h2>
            <p>
              {nombreCompleto ? `${nombreCompleto}: ` : ""}el movimiento quedó en el historial con tu nombre y el motivo.
            </p>
            {pendiente && (
              <div className="banner-aviso" role="alert">
                <AlertTriangle size={16} aria-hidden="true" />
                <div>
                  <strong>La baja en la terminal quedó pendiente.</strong> El cambio de estado sí se guardó, pero la
                  baja del usuario y su huella en el aparato no se pudo solicitar ahora. Se reintentará sola en unos
                  minutos; mientras tanto la persona todavía podría marcar (esas marcas entrarán señaladas como
                  «Persona inactiva»). Puedes seguirlo en las <a href="/tiempo/terminales/anomalias">Anomalías de la terminal</a>{" "}
                  (inconsistencias de baja).
                </div>
              </div>
            )}
            {desconocidas && (
              <div className="banner-aviso" role="alert">
                <AlertTriangle size={16} aria-hidden="true" />
                <div>
                  El movimiento se guardó, pero el sistema devolvió un aviso que requiere revisión. Avisa a Sistemas.
                </div>
              </div>
            )}
            {!pendiente && !desconocidas && resultado.bajasTerminal > 0 && (
              <div className="banner-aviso banner-aviso--info" role="status">
                <Info size={16} aria-hidden="true" />
                <div>
                  Se solicitó también la baja de {resultado.bajasTerminal}{" "}
                  {resultado.bajasTerminal === 1 ? "alta" : "altas"} en la terminal; el puente borrará el usuario y su
                  huella del aparato.
                </div>
              </div>
            )}
            <div className="botonera">
              <a href={id ? `/personas/${id}` : "/personas"} className="boton-con-icono boton-primario">
                Continuar a la ficha
              </a>
            </div>
          </div>
        </div>
      </AppShell>
    );
  }

  return (
    <AppShell>
      <form onSubmit={handleSubmit} className="contenedor-pagina">
        <nav className="migas">
          <a href="/personas">Personas</a> / <strong>Cambio de estado</strong>
        </nav>
        <h1>Cambio de estado</h1>
        <p className="subtitulo-pagina">
          Suspende, reactiva o da de baja a una persona. El motivo queda registrado en el
          historial y no puede editarse después.
        </p>

        {nombreCompleto && (
          <div className="cabecera-persona">
            <div className="identidad">
              <span className="avatar-iniciales">{iniciales}</span>
              <strong>{nombreCompleto}</strong>
            </div>
            {persona?.estado && (
              <span className={`insignia-estado ${persona.estado}`}>
                {ETIQUETA_ESTADO[persona.estado] ?? persona.estado}
              </span>
            )}
          </div>
        )}

        <fieldset className="fieldset-formulario">
          <legend className="encabezado-fieldset">Tipo de cambio</legend>
          <div className="opciones-seleccionables">
            <label className="opcion-seleccionable">
              <input type="radio" name="tipo_movimiento" value="suspension" required />
              <span className="icono-opcion">
                <ShieldAlert size={16} aria-hidden="true" />
              </span>
              <span className="texto-opcion">
                <strong>Suspensión temporal</strong>
                <small>
                  La persona conserva su historial y deja de marcar jornada hasta su
                  reactivación.
                </small>
              </span>
            </label>
            <label className="opcion-seleccionable">
              <input type="radio" name="tipo_movimiento" value="reactivacion" />
              <span className="icono-opcion">
                <RotateCcw size={16} aria-hidden="true" />
              </span>
              <span className="texto-opcion">
                <strong>Reactivación</strong>
                <small>Devuelve a la persona al estado activo y habilita de nuevo el registro de marcas.</small>
              </span>
            </label>
            <label className="opcion-seleccionable">
              <input type="radio" name="tipo_movimiento" value="baja_definitiva" />
              <span className="icono-opcion">
                <UserX size={16} aria-hidden="true" />
              </span>
              <span className="texto-opcion">
                <strong>Baja definitiva</strong>
                <small>Cierra la relación laboral. El historial se conserva, pero no admite reactivación.</small>
              </span>
            </label>
          </div>
        </fieldset>

        <label htmlFor="motivo">Motivo</label>
        <textarea id="motivo" name="motivo" required aria-describedby="motivo-ayuda" />
        <small className="ayuda-campo" id="motivo-ayuda">
          Queda asentado en el historial de la persona y no podrá editarse.
        </small>

        {error && <p role="alert">{error}</p>}
        <div className="botonera">
          <a href={id ? `/personas/${id}` : "/personas"}>Cancelar</a>
          <Button type="submit" cargando={enviando} textoCargando="Confirmando…">
            Confirmar
          </Button>
        </div>
      </form>
    </AppShell>
  );
}
