import { type FormEvent, useEffect, useState } from "react";
import { ArrowRight, ShieldCheck } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";

type Puesto = {
  id: string;
  nombre_puesto: string;
  activo: boolean;
};

type Permiso = {
  codigo: string;
  heredable: boolean;
  activo: boolean;
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

export function OtorgarPermisoPage() {
  const [puestos, setPuestos] = useState<Puesto[]>([]);
  const [estadoPuestos, setEstadoPuestos] = useState<EstadoCatalogo>("cargando");
  const [permisos, setPermisos] = useState<Permiso[]>([]);
  const [estadoPermisos, setEstadoPermisos] = useState<EstadoCatalogo>("cargando");
  const [error, setError] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);
  // Deep-link desde "Otorgar permiso" en la ficha de puesto (?puesto_id=...) — precarga la
  // selección así no hay que volver a buscar al mismo puesto del que se vino.
  const [puestoId, setPuestoId] = useState(
    () => new URLSearchParams(window.location.search).get("puesto_id") ?? ""
  );

  useEffect(() => {
    apiFetch("/api/puestos")
      .then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      })
      .then((datos: Puesto[]) => {
        setPuestos(datos.filter((p) => p.activo));
        setEstadoPuestos("listo");
      })
      .catch(() => setEstadoPuestos("error"));

    apiFetch("/api/permisos")
      .then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      })
      .then((datos: Permiso[]) => {
        setPermisos(datos.filter((p) => p.activo));
        setEstadoPermisos("listo");
      })
      .catch(() => setEstadoPermisos("error"));
  }, []);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    setEnviando(true);
    const f = new FormData(evento.currentTarget);
    const respuesta = await apiFetch("/api/permisos/otorgar", {
      method: "POST",
      body: JSON.stringify({
        puesto_id: f.get("puesto_id"),
        codigo: f.get("codigo"),
      }),
    });
    if (!respuesta.ok) {
      // El 422 de auto-otorgamiento/herencia (SCJ-PRO-05 G5/G5b) es una regla real que puede
      // dispararse siempre — se muestra el detail que manda el backend, no un genérico inventado.
      setError(await mensajeDeError(respuesta, "No se pudo otorgar el permiso."));
      setEnviando(false);
      return;
    }
    window.location.href = "/estructura/permisos";
  }

  const sinPuestos = estadoPuestos === "listo" && puestos.length === 0;
  const sinPermisos = estadoPermisos === "listo" && permisos.length === 0;
  const formularioDeshabilitado =
    sinPuestos || sinPermisos || estadoPuestos === "error" || estadoPermisos === "error";

  return (
    <AppShell>
      <form onSubmit={handleSubmit} className="contenedor-pagina">
        <nav className="migas">
          <a href="/estructura/permisos">Permisos</a> / <strong>Otorgar permiso</strong>
        </nav>
        <h1>Otorgar permiso</h1>
        <p className="subtitulo-pagina">Otorga un permiso del catálogo a un puesto activo.</p>

        <fieldset className="fieldset-formulario">
          <legend className="encabezado-fieldset">
            <span className="icono-seccion">
              <ShieldCheck size={16} aria-hidden="true" />
            </span>
            Datos del otorgamiento
          </legend>

          <div className="campo">
            <label htmlFor="puesto_id">Puesto destino</label>
            <select
              id="puesto_id"
              name="puesto_id"
              required
              disabled={sinPuestos || estadoPuestos === "error"}
              value={puestoId}
              onChange={(evento) => setPuestoId(evento.target.value)}
              aria-describedby={sinPuestos || estadoPuestos === "error" ? "puesto_id-ayuda" : undefined}
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
          </div>

          <div className="campo">
            <label htmlFor="codigo">Permiso</label>
            <select
              id="codigo"
              name="codigo"
              required
              disabled={sinPermisos || estadoPermisos === "error"}
              aria-describedby={sinPermisos || estadoPermisos === "error" ? "codigo-ayuda" : undefined}
            >
              <option value="">Selecciona un permiso</option>
              {permisos.map((permiso) => (
                <option key={permiso.codigo} value={permiso.codigo}>
                  {permiso.codigo}
                  {permiso.heredable ? " (heredable)" : ""}
                </option>
              ))}
            </select>
            {sinPermisos && (
              <small className="ayuda-campo" id="codigo-ayuda">
                No hay permisos activos en el catálogo.
              </small>
            )}
            {estadoPermisos === "error" && (
              <small className="ayuda-campo" id="codigo-ayuda">
                No se pudo cargar el catálogo de permisos.
              </small>
            )}
          </div>
        </fieldset>

        {error && <p role="alert">{error}</p>}
        <div className="botonera">
          <a href="/estructura/permisos">Cancelar</a>
          <Button
            type="submit"
            icono={ArrowRight}
            disabled={formularioDeshabilitado}
            cargando={enviando}
            textoCargando="Otorgando…"
          >
            Otorgar
          </Button>
        </div>
      </form>
    </AppShell>
  );
}
