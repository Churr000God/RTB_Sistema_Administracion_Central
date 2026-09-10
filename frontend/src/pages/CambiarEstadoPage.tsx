import { type FormEvent, useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { RotateCcw, ShieldAlert, UserX } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
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
    window.location.href = `/personas/${id}`;
  }

  const nombreCompleto =
    persona?.primer_nombre && persona?.apellido_paterno
      ? `${persona.primer_nombre} ${persona.apellido_paterno}`
      : null;
  const iniciales = nombreCompleto
    ? `${persona!.primer_nombre[0]}${persona!.apellido_paterno[0]}`.toUpperCase()
    : "";

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
