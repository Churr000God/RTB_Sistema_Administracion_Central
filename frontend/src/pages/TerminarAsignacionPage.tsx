import { type FormEvent, useEffect, useState } from "react";
import { useParams } from "react-router-dom";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Input } from "../components/Input";

type Asignacion = {
  id: string;
  persona_id: string;
  persona_nombre: string;
  nombre_puesto: string;
  nombre_departamento: string;
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

export function TerminarAsignacionPage() {
  const { id } = useParams<{ id: string }>();
  const [asignacion, setAsignacion] = useState<Asignacion | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);

  useEffect(() => {
    apiFetch(`/api/asignaciones/${id}`)
      .then((r) => r.json())
      .then(setAsignacion)
      .catch(() => undefined);
  }, [id]);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    setEnviando(true);
    const f = new FormData(evento.currentTarget);
    const respuesta = await apiFetch(`/api/asignaciones/${id}/terminar`, {
      method: "PATCH",
      body: JSON.stringify({
        vigente_hasta: f.get("vigente_hasta"),
      }),
    });
    if (!respuesta.ok) {
      setError(await mensajeDeError(respuesta, "No se pudo terminar la asignación."));
      setEnviando(false);
      return;
    }
    window.location.href = "/estructura/asignaciones";
  }

  const iniciales = asignacion?.persona_nombre
    ? asignacion.persona_nombre
        .trim()
        .split(/\s+/)
        .map((parte) => parte[0])
        .filter(Boolean)
        .slice(0, 2)
        .join("")
        .toUpperCase()
    : "";

  return (
    <AppShell>
      <form onSubmit={handleSubmit} className="contenedor-pagina">
        <nav className="migas">
          <a href="/estructura/asignaciones">Asignaciones</a> / <strong>Terminar asignación</strong>
        </nav>
        <h1>Terminar asignación</h1>
        <p className="subtitulo-pagina">
          Cierra la asignación vigente. La plaza queda libre para asignar a otra persona.
        </p>

        {asignacion && (
          <div className="cabecera-persona">
            <div className="identidad">
              <span className="avatar-iniciales">{iniciales}</span>
              <div>
                <strong>{asignacion.persona_nombre}</strong>
                <p className="meta-ficha">
                  {asignacion.nombre_puesto} · {asignacion.nombre_departamento}
                </p>
              </div>
            </div>
          </div>
        )}

        <div className="tarjeta-info">
          Esta acción sólo cierra la asignación. No cambia el estado de la persona ni afecta sus otros
          puestos vigentes, si tiene más de uno.
        </div>

        <fieldset className="fieldset-formulario">
          <legend className="encabezado-fieldset">Fecha de término</legend>
          <Input id="vigente_hasta" name="vigente_hasta" label="Vigente hasta" type="date" required />
        </fieldset>

        {error && <p role="alert">{error}</p>}
        <div className="botonera">
          <a href="/estructura/asignaciones">Cancelar</a>
          <Button type="submit" cargando={enviando} textoCargando="Terminando…">
            Confirmar término
          </Button>
        </div>
      </form>
    </AppShell>
  );
}
