import { type FormEvent, useEffect, useState } from "react";
import { ArrowRight, Users } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Input } from "../components/Input";

type Persona = {
  id: string;
  primer_nombre: string;
  apellido_paterno: string;
  estado: string;
};

type Puesto = {
  id: string;
  nombre_puesto: string;
  plazas_totales: number;
  activo: boolean;
};

type Asignacion = {
  puesto_id: string;
  vigente_hasta: string | null;
};

type EstadoCatalogo = "cargando" | "listo" | "error";

async function mensajeDeError(respuesta: Response, generico: string): Promise<string> {
  try {
    const cuerpo = await respuesta.json();
    if (typeof cuerpo?.detail === "string") return cuerpo.detail;
  } catch {
    // cuerpo no era JSON legible — cae al genérico
  }
  return generico;
}

export function AltaAsignacionPage() {
  const [personas, setPersonas] = useState<Persona[]>([]);
  const [estadoPersonas, setEstadoPersonas] = useState<EstadoCatalogo>("cargando");
  const [puestos, setPuestos] = useState<Puesto[]>([]);
  const [asignaciones, setAsignaciones] = useState<Asignacion[]>([]);
  const [estadoPuestos, setEstadoPuestos] = useState<EstadoCatalogo>("cargando");
  const [puestoSeleccionado, setPuestoSeleccionado] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);
  // Deep-link desde "Nueva asignación" en la ficha de persona (?persona_id=...) — precarga la
  // selección así no hay que volver a buscar a la misma persona de la que se vino.
  const [personaId, setPersonaId] = useState(
    () => new URLSearchParams(window.location.search).get("persona_id") ?? ""
  );

  useEffect(() => {
    apiFetch("/api/personas")
      .then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      })
      .then((datos: Persona[]) => {
        setPersonas(datos.filter((p) => p.estado === "activo"));
        setEstadoPersonas("listo");
      })
      .catch(() => setEstadoPersonas("error"));

    Promise.all([
      apiFetch("/api/puestos").then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      }),
      apiFetch("/api/asignaciones").then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      }),
    ])
      .then(([datosPuestos, datosAsignaciones]: [Puesto[], Asignacion[]]) => {
        setPuestos(datosPuestos.filter((p) => p.activo));
        setAsignaciones(datosAsignaciones);
        setEstadoPuestos("listo");
      })
      .catch(() => setEstadoPuestos("error"));
  }, []);

  function plazasLibres(puesto: Puesto): number {
    const ocupadas = asignaciones.filter((a) => a.puesto_id === puesto.id && !a.vigente_hasta).length;
    return puesto.plazas_totales - ocupadas;
  }

  const puestoActivo = puestos.find((p) => p.id === puestoSeleccionado) ?? null;

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    setEnviando(true);
    const f = new FormData(evento.currentTarget);
    const respuesta = await apiFetch("/api/asignaciones", {
      method: "POST",
      body: JSON.stringify({
        persona_id: f.get("persona_id"),
        puesto_id: f.get("puesto_id"),
        vigente_desde: f.get("vigente_desde"),
      }),
    });
    if (!respuesta.ok) {
      setError(await mensajeDeError(respuesta, "No se pudo registrar la asignación."));
      setEnviando(false);
      return;
    }
    window.location.href = "/estructura/asignaciones";
  }

  const sinPersonas = estadoPersonas === "listo" && personas.length === 0;
  const sinPuestos = estadoPuestos === "listo" && puestos.length === 0;
  const formularioDeshabilitado =
    sinPersonas || sinPuestos || estadoPersonas === "error" || estadoPuestos === "error";

  return (
    <AppShell>
      <form onSubmit={handleSubmit} className="contenedor-pagina">
        <nav className="migas">
          <a href="/estructura/asignaciones">Asignaciones</a> / <strong>Nueva asignación</strong>
        </nav>
        <h1>Nueva asignación</h1>
        <p className="subtitulo-pagina">Liga a una persona activa con un puesto activo con plaza libre.</p>

        <fieldset className="fieldset-formulario">
          <legend className="encabezado-fieldset">
            <span className="icono-seccion">
              <Users size={16} aria-hidden="true" />
            </span>
            Datos de la asignación
          </legend>

          <div className="campo">
            <label htmlFor="persona_id">Persona</label>
            <select
              id="persona_id"
              name="persona_id"
              required
              disabled={sinPersonas || estadoPersonas === "error"}
              value={personaId}
              onChange={(evento) => setPersonaId(evento.target.value)}
              aria-describedby={
                sinPersonas || estadoPersonas === "error" ? "persona_id-ayuda" : undefined
              }
            >
              <option value="">Selecciona una persona activa</option>
              {personas.map((persona) => (
                <option key={persona.id} value={persona.id}>
                  {persona.primer_nombre} {persona.apellido_paterno}
                </option>
              ))}
            </select>
            {sinPersonas && (
              <small className="ayuda-campo" id="persona_id-ayuda">
                No hay personas activas para asignar.
              </small>
            )}
            {estadoPersonas === "error" && (
              <small className="ayuda-campo" id="persona_id-ayuda">
                No se pudo cargar el padrón de personas.
              </small>
            )}
          </div>

          <div className="campo">
            <label htmlFor="puesto_id">Puesto</label>
            <select
              id="puesto_id"
              name="puesto_id"
              required
              disabled={sinPuestos || estadoPuestos === "error"}
              value={puestoSeleccionado}
              onChange={(evento) => setPuestoSeleccionado(evento.target.value)}
              aria-describedby={
                sinPuestos || estadoPuestos === "error" || puestoActivo ? "puesto_id-ayuda" : undefined
              }
            >
              <option value="">Selecciona un puesto activo</option>
              {puestos.map((puesto) => (
                <option key={puesto.id} value={puesto.id}>
                  {puesto.nombre_puesto}
                </option>
              ))}
            </select>
            {sinPuestos && (
              <small className="ayuda-campo" id="puesto_id-ayuda">
                No hay puestos activos disponibles.
              </small>
            )}
            {estadoPuestos === "error" && (
              <small className="ayuda-campo" id="puesto_id-ayuda">
                No se pudo cargar el catálogo de puestos.
              </small>
            )}
            {puestoActivo && (
              <small className="ayuda-campo" id="puesto_id-ayuda">
                {puestoActivo.plazas_totales - plazasLibres(puestoActivo)}/{puestoActivo.plazas_totales} ocupadas
                {plazasLibres(puestoActivo) <= 0 && " — sin plazas libres"}
              </small>
            )}
          </div>

          <Input id="vigente_desde" name="vigente_desde" label="Vigente desde" type="date" required />
        </fieldset>

        {error && <p role="alert">{error}</p>}
        <div className="botonera">
          <a href="/estructura/asignaciones">Cancelar</a>
          <Button
            type="submit"
            icono={ArrowRight}
            disabled={formularioDeshabilitado}
            cargando={enviando}
            textoCargando="Registrando…"
          >
            Registrar
          </Button>
        </div>
      </form>
    </AppShell>
  );
}
