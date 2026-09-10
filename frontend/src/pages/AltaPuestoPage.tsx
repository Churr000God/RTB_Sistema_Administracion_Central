import { type FormEvent, useEffect, useState } from "react";
import { ArrowRight, Building2 } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Input } from "../components/Input";

type Departamento = {
  id: string;
  nombre_departamento: string;
  activo: boolean;
};

type Puesto = {
  id: string;
  nombre_puesto: string;
  activo: boolean;
};

type EstadoCatalogo = "cargando" | "listo" | "error";

const NIVELES = [
  { value: "direccion", label: "Dirección" },
  { value: "gerencia", label: "Gerencia" },
  { value: "mando_medio", label: "Mando medio" },
  { value: "operativo", label: "Operativo" },
];

async function mensajeDeError(respuesta: Response, generico: string): Promise<string> {
  try {
    const cuerpo = await respuesta.json();
    if (typeof cuerpo?.detail === "string") return cuerpo.detail;
  } catch {
    // cuerpo no era JSON legible — cae al genérico
  }
  return generico;
}

export function AltaPuestoPage() {
  const [departamentos, setDepartamentos] = useState<Departamento[]>([]);
  const [estadoDepartamentos, setEstadoDepartamentos] = useState<EstadoCatalogo>("cargando");
  const [puestos, setPuestos] = useState<Puesto[]>([]);
  const [estadoPuestos, setEstadoPuestos] = useState<EstadoCatalogo>("cargando");
  const [error, setError] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);

  useEffect(() => {
    apiFetch("/api/departamentos")
      .then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      })
      .then((datos: Departamento[]) => {
        setDepartamentos(datos);
        setEstadoDepartamentos("listo");
      })
      .catch(() => setEstadoDepartamentos("error"));

    apiFetch("/api/puestos")
      .then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      })
      .then((datos: Puesto[]) => {
        setPuestos(datos);
        setEstadoPuestos("listo");
      })
      .catch(() => setEstadoPuestos("error"));
  }, []);

  const departamentosActivos = departamentos.filter((d) => d.activo);
  const puestosActivos = puestos.filter((p) => p.activo);

  const sinDepartamentos = estadoDepartamentos === "listo" && departamentosActivos.length === 0;
  const sinPuestosSuperiores = estadoPuestos === "listo" && puestosActivos.length === 0;
  const catalogosConError = estadoDepartamentos === "error" || estadoPuestos === "error";
  const formularioDeshabilitado = sinDepartamentos || sinPuestosSuperiores || catalogosConError;

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    setEnviando(true);
    const f = new FormData(evento.currentTarget);
    const respuesta = await apiFetch("/api/puestos", {
      method: "POST",
      body: JSON.stringify({
        departamento_id: f.get("departamento_id"),
        reporta_a_id: f.get("reporta_a_id"),
        nombre_puesto: f.get("nombre_puesto"),
        nivel: f.get("nivel"),
        plazas_totales: Number(f.get("plazas_totales")),
      }),
    });
    if (!respuesta.ok) {
      setError(await mensajeDeError(respuesta, "No se pudo registrar el alta."));
      setEnviando(false);
      return;
    }
    const puesto = await respuesta.json();
    window.location.href = `/estructura/puestos/${puesto.id}`;
  }

  return (
    <AppShell>
      <form onSubmit={handleSubmit} className="contenedor-pagina">
        <nav className="migas">
          <a href="/estructura/puestos">Puestos</a> / <strong>Nuevo puesto</strong>
        </nav>
        <h1>Nuevo puesto</h1>
        <p className="subtitulo-pagina">Registra un puesto dentro de un departamento activo.</p>

        <fieldset className="fieldset-formulario">
          <legend className="encabezado-fieldset">
            <span className="icono-seccion">
              <Building2 size={16} aria-hidden="true" />
            </span>
            Datos del puesto
          </legend>

          <div className="campo">
            <label htmlFor="departamento_id">Departamento</label>
            <select
              id="departamento_id"
              name="departamento_id"
              required
              disabled={sinDepartamentos || estadoDepartamentos === "error"}
              aria-describedby={
                sinDepartamentos || estadoDepartamentos === "error" ? "departamento_id-ayuda" : undefined
              }
            >
              <option value="">Selecciona un departamento</option>
              {departamentosActivos.map((departamento) => (
                <option key={departamento.id} value={departamento.id}>
                  {departamento.nombre_departamento}
                </option>
              ))}
            </select>
            {sinDepartamentos && (
              <small className="ayuda-campo" id="departamento_id-ayuda">
                No hay departamentos activos. Da de alta o reactiva uno antes de crear un puesto.
              </small>
            )}
            {estadoDepartamentos === "error" && (
              <small className="ayuda-campo" id="departamento_id-ayuda">
                No se pudo cargar el catálogo de departamentos.
              </small>
            )}
          </div>

          <div className="campo">
            <label htmlFor="reporta_a_id">Reporta a</label>
            <select
              id="reporta_a_id"
              name="reporta_a_id"
              required
              disabled={sinPuestosSuperiores || estadoPuestos === "error"}
              aria-describedby={
                sinPuestosSuperiores || estadoPuestos === "error" ? "reporta_a_id-ayuda" : undefined
              }
            >
              <option value="">Selecciona un puesto superior</option>
              {puestosActivos.map((puesto) => (
                <option key={puesto.id} value={puesto.id}>
                  {puesto.nombre_puesto}
                </option>
              ))}
            </select>
            {sinPuestosSuperiores && (
              <small className="ayuda-campo" id="reporta_a_id-ayuda">
                No hay puestos activos a los que reportar.
              </small>
            )}
            {estadoPuestos === "error" && (
              <small className="ayuda-campo" id="reporta_a_id-ayuda">
                No se pudo cargar el catálogo de puestos.
              </small>
            )}
          </div>

          <Input id="nombre_puesto" name="nombre_puesto" label="Nombre del puesto" required maxLength={100} />

          <div className="campo">
            <label htmlFor="nivel">Nivel</label>
            <select id="nivel" name="nivel" required defaultValue="">
              <option value="" disabled>
                Selecciona un nivel
              </option>
              {NIVELES.map((nivel) => (
                <option key={nivel.value} value={nivel.value}>
                  {nivel.label}
                </option>
              ))}
            </select>
          </div>

          <Input
            id="plazas_totales"
            name="plazas_totales"
            label="Plazas totales"
            type="number"
            min={1}
            defaultValue={1}
            required
          />
        </fieldset>

        {error && <p role="alert">{error}</p>}
        <div className="botonera">
          <a href="/estructura/puestos">Cancelar</a>
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
