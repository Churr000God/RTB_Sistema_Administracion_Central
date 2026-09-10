import { type FormEvent, useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { AlertTriangle } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Input } from "../components/Input";

type Asignacion = {
  id: string;
  persona_id: string;
  persona_nombre: string;
  puesto_id: string;
  nombre_puesto: string;
};

type Puesto = {
  id: string;
  nombre_puesto: string;
  plazas_totales: number;
  activo: boolean;
};

type AsignacionResumen = {
  puesto_id: string;
  vigente_hasta: string | null;
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

export function CambiarPuestoAsignacionPage() {
  const { id } = useParams<{ id: string }>();
  const [asignacion, setAsignacion] = useState<Asignacion | null>(null);
  const [puestos, setPuestos] = useState<Puesto[]>([]);
  const [asignaciones, setAsignaciones] = useState<AsignacionResumen[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);

  useEffect(() => {
    apiFetch(`/api/asignaciones/${id}`)
      .then((r) => r.json())
      .then(setAsignacion)
      .catch(() => undefined);

    Promise.all([
      apiFetch("/api/puestos").then((r) => (r.ok ? r.json() : [])),
      apiFetch("/api/asignaciones").then((r) => (r.ok ? r.json() : [])),
    ]).then(([datosPuestos, datosAsignaciones]: [Puesto[], AsignacionResumen[]]) => {
      setPuestos(datosPuestos.filter((p) => p.activo));
      setAsignaciones(datosAsignaciones);
    });
  }, [id]);

  const puestosDestino = puestos.filter((p) => p.id !== asignacion?.puesto_id);

  function plazasLibres(puesto: Puesto): number {
    const ocupadas = asignaciones.filter((a) => a.puesto_id === puesto.id && !a.vigente_hasta).length;
    return puesto.plazas_totales - ocupadas;
  }

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    setEnviando(true);
    const f = new FormData(evento.currentTarget);
    const respuesta = await apiFetch(`/api/asignaciones/${id}/cambiar-puesto`, {
      method: "POST",
      body: JSON.stringify({
        puesto_nuevo_id: f.get("puesto_nuevo_id"),
        fecha: f.get("fecha"),
      }),
    });
    if (!respuesta.ok) {
      setError(await mensajeDeError(respuesta, "No se pudo cambiar de puesto."));
      setEnviando(false);
      return;
    }
    window.location.href = "/estructura/asignaciones";
  }

  return (
    <AppShell>
      <form onSubmit={handleSubmit} className="contenedor-pagina">
        <nav className="migas">
          <a href="/estructura/asignaciones">Asignaciones</a> / <strong>Cambiar de puesto</strong>
        </nav>
        <h1>Cambiar de puesto</h1>
        <p className="subtitulo-pagina">
          Cierra la asignación actual y abre una nueva al mismo tiempo, en una sola operación.
        </p>

        {asignacion && (
          <div className="cabecera-persona">
            <div className="identidad">
              <div>
                <strong>{asignacion.persona_nombre}</strong>
                <p className="meta-ficha">Puesto actual: {asignacion.nombre_puesto}</p>
              </div>
            </div>
          </div>
        )}

        <div className="tarjeta-info">
          <AlertTriangle size={16} aria-hidden="true" />
          <span>
            Operación única e irreversible a medias: el puesto nuevo se valida antes de cerrar el
            actual. Si algo falla, no se cierra nada — pero una vez confirmado, no se puede deshacer
            la mitad del cambio.
          </span>
        </div>

        <fieldset className="fieldset-formulario">
          <legend className="encabezado-fieldset">Datos del cambio</legend>
          <div className="campo">
            <label htmlFor="puesto_nuevo_id">Puesto nuevo</label>
            <select id="puesto_nuevo_id" name="puesto_nuevo_id" required aria-describedby="puesto_nuevo_id-ayuda">
              <option value="">Selecciona un puesto activo</option>
              {puestosDestino.map((puesto) => (
                <option key={puesto.id} value={puesto.id}>
                  {puesto.nombre_puesto} — {puesto.plazas_totales - plazasLibres(puesto)}/
                  {puesto.plazas_totales} ocupadas
                </option>
              ))}
            </select>
            <small className="ayuda-campo" id="puesto_nuevo_id-ayuda">
              Debe estar activo y tener al menos una plaza libre.
            </small>
          </div>
          <Input
            id="fecha"
            name="fecha"
            label="Fecha del cambio"
            type="date"
            required
            ayuda="Se usa como fecha de término del puesto actual y de inicio del nuevo."
          />
        </fieldset>

        {error && <p role="alert">{error}</p>}
        <div className="botonera">
          <a href="/estructura/asignaciones">Cancelar</a>
          <Button type="submit" cargando={enviando} textoCargando="Cambiando…">
            Confirmar cambio
          </Button>
        </div>
      </form>
    </AppShell>
  );
}
