import { type FormEvent, useEffect, useState } from "react";
import { ArrowRight, Building2 } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Input } from "../components/Input";

type Area = {
  id: string;
  nombre_area: string;
  activo: boolean;
};

type EstadoAreas = "cargando" | "listo" | "error";

async function mensajeDeError(respuesta: Response, generico: string): Promise<string> {
  try {
    const cuerpo = await respuesta.json();
    if (typeof cuerpo?.detail === "string") return cuerpo.detail;
  } catch {
    // cuerpo no era JSON legible — cae al genérico
  }
  return generico;
}

export function AltaDepartamentoPage() {
  const [areas, setAreas] = useState<Area[]>([]);
  const [estadoAreas, setEstadoAreas] = useState<EstadoAreas>("cargando");
  const [error, setError] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);

  useEffect(() => {
    apiFetch("/api/areas")
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datos: Area[]) => {
        setAreas(datos);
        setEstadoAreas("listo");
      })
      .catch(() => setEstadoAreas("error"));
  }, []);

  const areasActivas = areas.filter((area) => area.activo);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    setEnviando(true);
    const f = new FormData(evento.currentTarget);
    const respuesta = await apiFetch("/api/departamentos", {
      method: "POST",
      body: JSON.stringify({
        area_id: f.get("area_id"),
        nombre_departamento: f.get("nombre_departamento"),
      }),
    });
    if (!respuesta.ok) {
      if (respuesta.status === 409) {
        setError("Ya existe un departamento con ese nombre.");
      } else if (respuesta.status === 400 || respuesta.status === 422) {
        setError("El área seleccionada no existe o ya no está activa.");
      } else {
        setError(await mensajeDeError(respuesta, "No se pudo registrar el alta."));
      }
      setEnviando(false);
      return;
    }
    const departamento = await respuesta.json();
    window.location.href = `/estructura/departamentos/${departamento.id}`;
  }

  const sinAreasDisponibles = estadoAreas === "listo" && areasActivas.length === 0;
  const noSePudoCargarAreas = estadoAreas === "error";

  return (
    <AppShell>
      <form onSubmit={handleSubmit} className="contenedor-pagina">
        <nav className="migas">
          <a href="/estructura/departamentos">Departamentos</a> / <strong>Nuevo departamento</strong>
        </nav>
        <h1>Nuevo departamento</h1>
        <p className="subtitulo-pagina">Registra un departamento dentro de un área activa.</p>

        <fieldset className="fieldset-formulario">
          <legend className="encabezado-fieldset">
            <span className="icono-seccion">
              <Building2 size={16} aria-hidden="true" />
            </span>
            Datos del departamento
          </legend>
          <div className="campo">
            <label htmlFor="area_id">Área</label>
            <select
              id="area_id"
              name="area_id"
              required
              disabled={sinAreasDisponibles || noSePudoCargarAreas}
              aria-describedby={
                sinAreasDisponibles || noSePudoCargarAreas ? "area_id-ayuda" : undefined
              }
            >
              <option value="">Selecciona un área</option>
              {areasActivas.map((area) => (
                <option key={area.id} value={area.id}>
                  {area.nombre_area}
                </option>
              ))}
            </select>
            {sinAreasDisponibles && (
              <small className="ayuda-campo" id="area_id-ayuda">
                No hay áreas activas. Da de alta o reactiva un área antes de crear un departamento.
              </small>
            )}
            {noSePudoCargarAreas && (
              <small className="ayuda-campo" id="area_id-ayuda">
                No se pudo cargar el catálogo de áreas.
              </small>
            )}
          </div>
          <Input
            id="nombre_departamento"
            name="nombre_departamento"
            label="Nombre del departamento"
            required
            maxLength={100}
            ayuda="Debe ser único en todo el catálogo."
          />
        </fieldset>

        {error && <p role="alert">{error}</p>}
        <div className="botonera">
          <a href="/estructura/departamentos">Cancelar</a>
          <Button
            type="submit"
            icono={ArrowRight}
            disabled={sinAreasDisponibles || noSePudoCargarAreas}
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
