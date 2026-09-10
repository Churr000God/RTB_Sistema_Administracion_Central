import { useEffect, useMemo, useState } from "react";
import { AlertCircle, Building2, Loader2, Plus, Search } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Badge } from "../components/Badge";

type Departamento = {
  id: string;
  area_id: string;
  nombre_departamento: string;
  activo: boolean;
  creado_en: string;
  actualizado_en: string;
};

type Area = {
  id: string;
  nombre_area: string;
};

type EstadoCarga = "cargando" | "listo" | "error";

function normalizar(texto: string): string {
  return texto
    .normalize("NFD")
    .replace(new RegExp("[\\u0300-\\u036f]", "g"), "")
    .toLowerCase();
}

export function DirectorioDepartamentosPage() {
  const [departamentos, setDepartamentos] = useState<Departamento[]>([]);
  const [nombresArea, setNombresArea] = useState<Record<string, string>>({});
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [busqueda, setBusqueda] = useState("");
  const [filtroEstado, setFiltroEstado] = useState("");

  function cargar() {
    setEstadoCarga("cargando");
    Promise.all([
      apiFetch("/api/departamentos").then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      }),
      apiFetch("/api/areas").then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      }),
    ])
      .then(([datosDepartamentos, datosAreas]: [Departamento[], Area[]]) => {
        setDepartamentos(datosDepartamentos);
        setNombresArea(Object.fromEntries(datosAreas.map((a) => [a.id, a.nombre_area])));
        setEstadoCarga("listo");
      })
      .catch(() => setEstadoCarga("error"));
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const metricas = useMemo(
    () => ({
      total: departamentos.length,
      activos: departamentos.filter((d) => d.activo).length,
      inactivos: departamentos.filter((d) => !d.activo).length,
    }),
    [departamentos],
  );

  const filtrados = useMemo(() => {
    const consulta = normalizar(busqueda.trim());
    return departamentos.filter((departamento) => {
      const coincideBusqueda =
        !consulta || normalizar(departamento.nombre_departamento).includes(consulta);
      const coincideEstado =
        !filtroEstado || (filtroEstado === "activo" ? departamento.activo : !departamento.activo);
      return coincideBusqueda && coincideEstado;
    });
  }, [departamentos, busqueda, filtroEstado]);

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          Estructura organizacional › <strong>Departamentos</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Departamentos</h1>
            <p className="subtitulo-pagina">Catálogo de departamentos por área.</p>
          </div>
          <Button
            href="/estructura/departamentos/nueva"
            variante="primario"
            icono={Plus}
            posicionIcono="izquierda"
          >
            Nuevo departamento
          </Button>
        </div>

        <div className="banda-metricas">
          <div className="metrica">
            <span className="etiqueta-metrica">Total</span>
            <strong>{metricas.total}</strong>
          </div>
          <div className="metrica">
            <span className="etiqueta-metrica">
              <span className="punto punto--exito" aria-hidden="true" />
              Activos
            </span>
            <strong>{metricas.activos}</strong>
          </div>
          <div className="metrica">
            <span className="etiqueta-metrica">
              <span className="punto punto--peligro" aria-hidden="true" />
              Inactivos
            </span>
            <strong>{metricas.inactivos}</strong>
          </div>
        </div>

        <div className="barra-filtros">
          <div className="campo-con-icono">
            <Search size={16} className="icono-campo" aria-hidden="true" />
            <input
              type="search"
              placeholder="Buscar por nombre"
              value={busqueda}
              onChange={(evento) => setBusqueda(evento.target.value)}
              aria-label="Buscar por nombre"
            />
          </div>
          <select
            value={filtroEstado}
            onChange={(evento) => setFiltroEstado(evento.target.value)}
            aria-label="Filtrar por estado"
          >
            <option value="">Estado: Todos</option>
            <option value="activo">Activo</option>
            <option value="inactivo">Inactivo</option>
          </select>
        </div>

        {estadoCarga === "cargando" && (
          <p className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando departamentos…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar el listado de departamentos
            </strong>
            <p>Ocurrió un problema al consultar el catálogo.</p>
            <button type="button" onClick={cargar}>
              Reintentar
            </button>
          </div>
        )}

        {estadoCarga === "listo" && filtrados.length === 0 && (
          <div className="estado-vacio">
            <Building2 size={28} aria-hidden="true" />
            <p>No hay departamentos registrados o tu cuenta no tiene acceso al catálogo.</p>
          </div>
        )}

        {estadoCarga === "listo" && filtrados.length > 0 && (
          <>
            <div className="tabla-desplazable">
              <table>
                <thead>
                  <tr>
                    <th>Nombre</th>
                    <th>Área</th>
                    <th>Estado</th>
                  </tr>
                </thead>
                <tbody>
                  {filtrados.map((departamento) => (
                    <tr key={departamento.id}>
                      <td>
                        <a
                          href={`/estructura/departamentos/${departamento.id}`}
                          style={{ fontWeight: 600 }}
                        >
                          {departamento.nombre_departamento}
                        </a>
                      </td>
                      <td>{nombresArea[departamento.area_id] ?? "—"}</td>
                      <td>
                        <Badge variante={departamento.activo ? "exito" : "peligro"}>
                          {departamento.activo ? "Activo" : "Inactivo"}
                        </Badge>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="pie-tabla">
              Mostrando {filtrados.length} de {departamentos.length} departamentos
            </p>
          </>
        )}
      </div>
    </AppShell>
  );
}
