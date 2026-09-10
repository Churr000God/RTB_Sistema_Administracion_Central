import { useEffect, useMemo, useState } from "react";
import { AlertCircle, Loader2, Search, Wrench } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { etiquetaMotivo } from "../lib/motivosRevision";
import { AppShell } from "../layouts/AppShell";
import { Badge } from "../components/Badge";
import { Input } from "../components/Input";

type Excepcion = {
  id: number;
  motivo_revision: string;
  estado: "pendiente" | "resuelto";
  creado_en: string;
  marca_id: number | null;
  dia_id: number | null;
  persona_nombre: string | null;
  momento_dispositivo: string | null;
};

type EstadoCarga = "cargando" | "listo" | "error";

type Orden = "fecha_desc" | "fecha_asc" | "motivo_asc" | "persona_asc";

function normalizar(texto: string): string {
  return texto
    .normalize("NFD")
    .replace(new RegExp("[\\u0300-\\u036f]", "g"), "")
    .toLowerCase();
}

function formatearFechaHora(fecha: string | null): string {
  if (!fecha) return "—";
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleString("es-MX", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function ColaExcepcionesPage() {
  const [excepciones, setExcepciones] = useState<Excepcion[]>([]);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [busqueda, setBusqueda] = useState("");
  const [filtroMotivo, setFiltroMotivo] = useState("");
  const [filtroDesde, setFiltroDesde] = useState("");
  const [filtroHasta, setFiltroHasta] = useState("");
  const [orden, setOrden] = useState<Orden>("fecha_desc");

  function cargar() {
    setEstadoCarga("cargando");
    apiFetch("/api/excepciones")
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datos: Excepcion[]) => {
        // El servidor ya filtra a estado='pendiente'. marca_id != null: excepciones de un día
        // sin checada (dia_id) las resuelve la bandeja de ausencias (SCJ-PRO-08) al
        // aprobar/rechazar — se cierran solas por trigger, no tienen corrección propia acá.
        setExcepciones(datos.filter((e) => e.marca_id !== null));
        setEstadoCarga("listo");
      })
      .catch(() => setEstadoCarga("error"));
  }

  useEffect(() => {
    cargar();
  }, []);

  const porMotivo = useMemo(() => {
    const conteo = new Map<string, number>();
    for (const excepcion of excepciones) {
      conteo.set(excepcion.motivo_revision, (conteo.get(excepcion.motivo_revision) ?? 0) + 1);
    }
    return conteo;
  }, [excepciones]);

  const motivosPresentes = useMemo(
    () => [...porMotivo.keys()].sort((a, b) => a.localeCompare(b)),
    [porMotivo],
  );

  const filtradas = useMemo(() => {
    const consulta = normalizar(busqueda.trim());
    const desde = filtroDesde ? new Date(`${filtroDesde}T00:00:00`) : null;
    const hasta = filtroHasta ? new Date(`${filtroHasta}T23:59:59`) : null;

    const resultado = excepciones.filter((excepcion) => {
      const coincideBusqueda = !consulta || normalizar(excepcion.persona_nombre ?? "").includes(consulta);
      const coincideMotivo = !filtroMotivo || excepcion.motivo_revision === filtroMotivo;
      const fechaDetectada = new Date(excepcion.creado_en);
      const coincideDesde = !desde || fechaDetectada >= desde;
      const coincideHasta = !hasta || fechaDetectada <= hasta;
      return coincideBusqueda && coincideMotivo && coincideDesde && coincideHasta;
    });

    return resultado.sort((a, b) => {
      switch (orden) {
        case "fecha_asc":
          return a.creado_en.localeCompare(b.creado_en);
        case "motivo_asc":
          return a.motivo_revision.localeCompare(b.motivo_revision);
        case "persona_asc":
          return (a.persona_nombre ?? "").localeCompare(b.persona_nombre ?? "");
        case "fecha_desc":
        default:
          return b.creado_en.localeCompare(a.creado_en);
      }
    });
  }, [excepciones, busqueda, filtroMotivo, filtroDesde, filtroHasta, orden]);

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <strong>Excepciones pendientes</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Excepciones pendientes</h1>
            <p className="subtitulo-pagina">
              Marcas apartadas para revisión — corrígelas para cerrar la excepción.
            </p>
          </div>
        </div>

        {estadoCarga === "listo" && excepciones.length > 0 && (
          <div className="banda-metricas">
            <div className="metrica">
              <span className="etiqueta-metrica">
                <span className="punto punto--aviso" aria-hidden="true" />
                Pendientes
              </span>
              <strong>{excepciones.length}</strong>
            </div>
            {[...porMotivo.entries()].map(([motivo, cantidad]) => (
              <div className="metrica" key={motivo}>
                <span className="etiqueta-metrica">{etiquetaMotivo(motivo)}</span>
                <strong>{cantidad}</strong>
              </div>
            ))}
          </div>
        )}

        {estadoCarga === "listo" && excepciones.length > 0 && (
          <div className="barra-filtros">
            <div className="campo-con-icono">
              <Search size={16} className="icono-campo" aria-hidden="true" />
              <input
                type="search"
                placeholder="Buscar por persona"
                value={busqueda}
                onChange={(evento) => setBusqueda(evento.target.value)}
                aria-label="Buscar por persona"
              />
            </div>
            <div className="grupo-filtros-secundarios">
              <select
                value={filtroMotivo}
                onChange={(evento) => setFiltroMotivo(evento.target.value)}
                aria-label="Filtrar por motivo"
              >
                <option value="">Motivo: Todos</option>
                {motivosPresentes.map((motivo) => (
                  <option key={motivo} value={motivo}>
                    {etiquetaMotivo(motivo)}
                  </option>
                ))}
              </select>
              <Input
                id="filtro-detectada-desde"
                label="Detectada desde"
                type="date"
                value={filtroDesde}
                onChange={(evento) => setFiltroDesde(evento.target.value)}
              />
              <Input
                id="filtro-detectada-hasta"
                label="Detectada hasta"
                type="date"
                value={filtroHasta}
                onChange={(evento) => setFiltroHasta(evento.target.value)}
              />
              <select
                value={orden}
                onChange={(evento) => setOrden(evento.target.value as Orden)}
                aria-label="Ordenar por"
              >
                <option value="fecha_desc">Detectada: más recientes primero</option>
                <option value="fecha_asc">Detectada: más antiguas primero</option>
                <option value="motivo_asc">Motivo (A-Z)</option>
                <option value="persona_asc">Persona (A-Z)</option>
              </select>
            </div>
          </div>
        )}

        {estadoCarga === "cargando" && (
          <p className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando excepciones…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar la cola de excepciones
            </strong>
            <p>Ocurrió un problema al consultar las excepciones pendientes.</p>
            <button type="button" onClick={cargar}>
              Reintentar
            </button>
          </div>
        )}

        {estadoCarga === "listo" && excepciones.length === 0 && (
          <div className="estado-vacio">
            <p>No hay excepciones de marca pendientes.</p>
          </div>
        )}

        {estadoCarga === "listo" && excepciones.length > 0 && filtradas.length === 0 && (
          <div className="estado-vacio">
            <p>Ninguna excepción coincide con la búsqueda.</p>
          </div>
        )}

        {estadoCarga === "listo" && filtradas.length > 0 && (
          <div className="tabla-desplazable">
            <table>
              <thead>
                <tr>
                  <th>Persona</th>
                  <th>Marca original</th>
                  <th>Motivo</th>
                  <th>Detectada</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {filtradas.map((excepcion) => (
                  <tr key={excepcion.id}>
                    <td>{excepcion.persona_nombre ?? "—"}</td>
                    <td>{formatearFechaHora(excepcion.momento_dispositivo)}</td>
                    <td>
                      <Badge variante="aviso">
                        {etiquetaMotivo(excepcion.motivo_revision)}
                      </Badge>
                    </td>
                    <td>{formatearFechaHora(excepcion.creado_en)}</td>
                    <td>
                      <a
                        href={`/tiempo/excepciones/${excepcion.id}/corregir`}
                        className="boton-con-icono"
                      >
                        <Wrench size={14} aria-hidden="true" />
                        Corregir
                      </a>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </AppShell>
  );
}
