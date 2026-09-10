import { useEffect, useMemo, useState } from "react";
import { AlertCircle, Building2, Loader2, Plus, Search } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Badge } from "../components/Badge";

type Area = {
  id: string;
  nombre_area: string;
  activo: boolean;
  creado_en: string;
  actualizado_en: string;
};

type EstadoCarga = "cargando" | "listo" | "error";

function normalizar(texto: string): string {
  return texto
    .normalize("NFD")
    .replace(new RegExp("[\\u0300-\\u036f]", "g"), "")
    .toLowerCase();
}

export function DirectorioAreasPage() {
  const [areas, setAreas] = useState<Area[]>([]);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [busqueda, setBusqueda] = useState("");
  const [filtroEstado, setFiltroEstado] = useState("");

  function cargar() {
    setEstadoCarga("cargando");
    apiFetch("/api/areas")
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datos: Area[]) => {
        setAreas(datos);
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
      total: areas.length,
      activas: areas.filter((a) => a.activo).length,
      inactivas: areas.filter((a) => !a.activo).length,
    }),
    [areas],
  );

  const filtradas = useMemo(() => {
    const consulta = normalizar(busqueda.trim());
    return areas.filter((area) => {
      const coincideBusqueda = !consulta || normalizar(area.nombre_area).includes(consulta);
      const coincideEstado =
        !filtroEstado || (filtroEstado === "activo" ? area.activo : !area.activo);
      return coincideBusqueda && coincideEstado;
    });
  }, [areas, busqueda, filtroEstado]);

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          Estructura organizacional › <strong>Áreas</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Áreas</h1>
            <p className="subtitulo-pagina">Catálogo de áreas de la organización.</p>
          </div>
          <Button href="/estructura/areas/nueva" variante="primario" icono={Plus} posicionIcono="izquierda">
            Nueva área
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
              Activas
            </span>
            <strong>{metricas.activas}</strong>
          </div>
          <div className="metrica">
            <span className="etiqueta-metrica">
              <span className="punto punto--peligro" aria-hidden="true" />
              Inactivas
            </span>
            <strong>{metricas.inactivas}</strong>
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
            Cargando áreas…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar el listado de áreas
            </strong>
            <p>Ocurrió un problema al consultar el catálogo.</p>
            <button type="button" onClick={cargar}>
              Reintentar
            </button>
          </div>
        )}

        {estadoCarga === "listo" && filtradas.length === 0 && (
          <div className="estado-vacio">
            <Building2 size={28} aria-hidden="true" />
            <p>No hay áreas registradas o tu cuenta no tiene acceso al catálogo.</p>
          </div>
        )}

        {estadoCarga === "listo" && filtradas.length > 0 && (
          <>
            <div className="tabla-desplazable">
              <table>
                <thead>
                  <tr>
                    <th>Nombre</th>
                    <th>Estado</th>
                  </tr>
                </thead>
                <tbody>
                  {filtradas.map((area) => (
                    <tr key={area.id}>
                      <td>
                        <a href={`/estructura/areas/${area.id}`} style={{ fontWeight: 600 }}>
                          {area.nombre_area}
                        </a>
                      </td>
                      <td>
                        <Badge variante={area.activo ? "exito" : "peligro"}>
                          {area.activo ? "Activo" : "Inactivo"}
                        </Badge>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="pie-tabla">
              Mostrando {filtradas.length} de {areas.length} áreas
            </p>
          </>
        )}
      </div>
    </AppShell>
  );
}
