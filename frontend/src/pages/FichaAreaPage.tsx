import { type FormEvent, useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { AlertCircle, Loader2 } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { Badge } from "../components/Badge";
import { Input } from "../components/Input";

type Area = {
  id: string;
  nombre_area: string;
  activo: boolean;
  creado_en: string;
  actualizado_en: string;
};

type Departamento = {
  id: string;
  area_id: string;
  nombre_departamento: string;
  activo: boolean;
};

type EstadoCarga = "cargando" | "listo" | "error";
type EstadoDepartamentos = "cargando" | "listo" | "error" | "sin_permiso";

function formatearFecha(fecha?: string | null): string {
  if (!fecha) return "—";
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" });
}

async function mensajeDeError(respuesta: Response, generico: string): Promise<string> {
  try {
    const cuerpo = await respuesta.json();
    if (typeof cuerpo?.detail === "string") return cuerpo.detail;
  } catch {
    // cuerpo no era JSON legible — cae al genérico
  }
  return generico;
}

export function FichaAreaPage() {
  const { id } = useParams<{ id: string }>();
  const [area, setArea] = useState<Area | null>(null);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [error, setError] = useState<string | null>(null);
  const [departamentos, setDepartamentos] = useState<Departamento[]>([]);
  const [estadoDepartamentos, setEstadoDepartamentos] = useState<EstadoDepartamentos>("cargando");
  const [guardando, setGuardando] = useState(false);
  const [cambiandoEstado, setCambiandoEstado] = useState(false);

  function cargar() {
    setEstadoCarga("cargando");
    apiFetch(`/api/areas/${id}`)
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datosArea: Area) => {
        setArea(datosArea);
        setEstadoCarga("listo");

        // Sin endpoint filtrado por área — se pide el catálogo completo y se filtra acá,
        // mismo criterio que FichaPuestoPage con /api/permisos/vigentes. El gate de
        // /api/departamentos es distinto (departamento_lectura/edicion) al de esta página
        // (area_lectura/edicion): quien ve el área puede no tener permiso sobre departamentos,
        // así que un 403 acá degrada sólo esta tarjeta, no la página completa.
        setEstadoDepartamentos("cargando");
        apiFetch("/api/departamentos")
          .then((r) => {
            if (r.status === 403) throw new Error("sin_permiso");
            if (!r.ok) throw new Error(`status ${r.status}`);
            return r.json();
          })
          .then((datosDepartamentos: Departamento[]) => {
            setDepartamentos(datosDepartamentos.filter((d) => d.area_id === datosArea.id));
            setEstadoDepartamentos("listo");
          })
          .catch((errorDepartamentos: Error) =>
            setEstadoDepartamentos(errorDepartamentos.message === "sin_permiso" ? "sin_permiso" : "error")
          );
      })
      .catch(() => setEstadoCarga("error"));
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  async function handleRenombrar(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    setGuardando(true);
    const f = new FormData(evento.currentTarget);
    const respuesta = await apiFetch(`/api/areas/${id}`, {
      method: "PATCH",
      body: JSON.stringify({ nombre_area: f.get("nombre_area") }),
    });
    if (!respuesta.ok) {
      if (respuesta.status === 409) {
        setError("Ya existe un área con ese nombre.");
      } else {
        setError(await mensajeDeError(respuesta, "No se pudo guardar el cambio."));
      }
      setGuardando(false);
      return;
    }
    setArea(await respuesta.json());
    setGuardando(false);
  }

  async function handleEstado(nuevoActivo: boolean) {
    setError(null);
    setCambiandoEstado(true);
    const respuesta = await apiFetch(`/api/areas/${id}/estado`, {
      method: "PATCH",
      body: JSON.stringify({ activo: nuevoActivo }),
    });
    if (!respuesta.ok) {
      setError(await mensajeDeError(respuesta, "No se pudo cambiar el estado del área."));
      setCambiandoEstado(false);
      return;
    }
    setArea(await respuesta.json());
    setCambiandoEstado(false);
  }

  const departamentosActivos = departamentos.filter((d) => d.activo);
  const departamentosInactivos = departamentos.filter((d) => !d.activo);

  if (estadoCarga === "cargando") {
    return (
      <AppShell>
        <p className="contenedor-pagina" style={{ marginTop: "2.5rem" }}>
          <span className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando…
          </span>
        </p>
      </AppShell>
    );
  }

  if (estadoCarga === "error" || !area) {
    return (
      <AppShell>
        <div className="contenedor-pagina" style={{ marginTop: "2.5rem" }}>
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar esta área
            </strong>
            <p>Ocurrió un problema al consultar el catálogo.</p>
            <button type="button" onClick={cargar}>
              Reintentar
            </button>
          </div>
        </div>
      </AppShell>
    );
  }

  return (
    <AppShell>
      <div className="contenedor-pagina">
        <nav className="migas">
          <a href="/estructura/areas">Áreas</a> / <strong>{area.nombre_area}</strong>
        </nav>

        <div className="cabecera-persona cabecera-ficha">
          <div className="identidad">
            <div className="fila-nombre-badge">
              <strong>{area.nombre_area}</strong>
              <Badge estado={area.activo ? "activo" : "baja_definitiva"}>
                {area.activo ? "Activo" : "Inactivo"}
              </Badge>
            </div>
          </div>
          <div className="botonera">
            {area.activo ? (
              <Button
                type="button"
                onClick={() => handleEstado(false)}
                cargando={cambiandoEstado}
                textoCargando="Desactivando…"
              >
                Desactivar área
              </Button>
            ) : (
              <Button
                type="button"
                onClick={() => handleEstado(true)}
                variante="primario"
                cargando={cambiandoEstado}
                textoCargando="Reactivando…"
              >
                Reactivar área
              </Button>
            )}
          </div>
        </div>

        {error && <p role="alert">{error}</p>}

        <Card as="form" onSubmit={handleRenombrar}>
          <h3>Nombre del área</h3>
          <Input id="nombre_area" name="nombre_area" label="Nombre" required maxLength={100} defaultValue={area.nombre_area} />
          <div className="botonera">
            <Button type="submit" cargando={guardando} textoCargando="Guardando…">
              Guardar
            </Button>
          </div>
        </Card>

        <Card>
          <h3>Departamentos de esta área</h3>
          {estadoDepartamentos === "cargando" && (
            <p className="boton-con-icono">
              <Loader2 size={14} className="icono-girando" aria-hidden="true" />
              Cargando departamentos…
            </p>
          )}
          {estadoDepartamentos === "sin_permiso" && (
            <p>No tienes permiso para ver los departamentos de esta área.</p>
          )}
          {estadoDepartamentos === "error" && <p>No se pudieron cargar los departamentos de esta área.</p>}
          {estadoDepartamentos === "listo" && departamentos.length === 0 && (
            <p>Esta área no tiene departamentos registrados.</p>
          )}
          {estadoDepartamentos === "listo" && departamentos.length > 0 && (
            <>
              {departamentosActivos.length > 0 && (
                <>
                  <p className="eyebrow-seccion">Activos</p>
                  <ul className="lista-historial-resumido">
                    {departamentosActivos.map((departamento) => (
                      <li key={departamento.id}>
                        <a href={`/estructura/departamentos/${departamento.id}`}>
                          {departamento.nombre_departamento}
                        </a>
                        <Badge estado="activo">Activo</Badge>
                      </li>
                    ))}
                  </ul>
                </>
              )}
              {departamentosInactivos.length > 0 && (
                <>
                  <p className="eyebrow-seccion">Inactivos</p>
                  <ul className="lista-historial-resumido">
                    {departamentosInactivos.map((departamento) => (
                      <li key={departamento.id}>
                        <a href={`/estructura/departamentos/${departamento.id}`}>
                          {departamento.nombre_departamento}
                        </a>
                        <Badge estado="baja_definitiva">Inactivo</Badge>
                      </li>
                    ))}
                  </ul>
                </>
              )}
            </>
          )}
        </Card>

        <Card>
          <h3>Fechas</h3>
          <div className="rejilla-datos">
            <div className="dato">
              <span>Creado el</span>
              <strong>{formatearFecha(area.creado_en)}</strong>
            </div>
            <div className="dato">
              <span>Última actualización</span>
              <strong>{formatearFecha(area.actualizado_en)}</strong>
            </div>
          </div>
        </Card>
      </div>
    </AppShell>
  );
}
