import { useEffect, useMemo, useState } from "react";
import { AlertCircle, Loader2, Plus, Search, Users } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";

type Persona = {
  id: string;
  primer_nombre: string;
  apellido_paterno: string;
  estado: string;
  fecha_ingreso?: string;
  fecha_baja?: string | null;
};

type Asignacion = {
  persona_id: string;
  puesto_id: string;
  nombre_puesto: string;
  nombre_departamento: string;
  nombre_area: string;
  vigente_hasta: string | null;
};

type DatosAsignacionPersona = {
  puestos: string[];
  puestoIds: string[];
  departamentos: string[];
  areas: string[];
};

type EstadoCarga = "cargando" | "listo" | "error";
type EstadoAsignaciones = "cargando" | "listo" | "error" | "sin_permiso";

const ETIQUETA_ESTADO: Record<string, string> = {
  activo: "Activo",
  suspension: "Suspensión",
  baja_definitiva: "Baja",
};

const CLASE_ESTADO: Record<string, string> = {
  activo: "insignia--exito",
  suspension: "insignia--aviso",
  baja_definitiva: "insignia--peligro",
};

function normalizar(texto: string): string {
  return texto
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase();
}

function formatearFecha(fecha?: string | null): string {
  if (!fecha) return "—";
  const valor = new Date(`${fecha}T00:00:00`);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" });
}

function inicialesDe(persona: Persona): string {
  return `${persona.primer_nombre[0] ?? ""}${persona.apellido_paterno[0] ?? ""}`.toUpperCase();
}

export function DirectorioPersonasPage() {
  const [personas, setPersonas] = useState<Persona[]>([]);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [busqueda, setBusqueda] = useState("");
  const [filtroEstado, setFiltroEstado] = useState("");
  const [asignaciones, setAsignaciones] = useState<Asignacion[]>([]);
  const [estadoAsignaciones, setEstadoAsignaciones] = useState<EstadoAsignaciones>("cargando");
  const [filtroPuesto, setFiltroPuesto] = useState("");
  const [filtroDepartamento, setFiltroDepartamento] = useState("");
  const [filtroArea, setFiltroArea] = useState("");

  function cargar() {
    setEstadoCarga("cargando");
    apiFetch("/api/personas")
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datos: Persona[]) => {
        setPersonas(datos);
        setEstadoCarga("listo");
      })
      .catch(() => setEstadoCarga("error"));

    // Independiente del fetch de personas -- distinto gate de permisos (asignacion_lectura/
    // edicion) y distinta tabla; un 403 acá sólo degrada las columnas de puesto/departamento/
    // área, no debe tumbar el padrón completo. GET /api/asignaciones ya trae denormalizado
    // hasta el nombre del área (AsignacionConDetalle en el backend) -- no hace falta cruzar
    // además con /api/puestos o /api/departamentos.
    setEstadoAsignaciones("cargando");
    apiFetch("/api/asignaciones")
      .then((r) => {
        if (r.status === 403) throw new Error("sin_permiso");
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      })
      .then((datos: Asignacion[]) => {
        setAsignaciones(datos.filter((a) => !a.vigente_hasta));
        setEstadoAsignaciones("listo");
      })
      .catch((e: Error) => setEstadoAsignaciones(e.message === "sin_permiso" ? "sin_permiso" : "error"));
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const metricas = useMemo(() => {
    const inicioMes = new Date();
    inicioMes.setDate(1);
    inicioMes.setHours(0, 0, 0, 0);
    return {
      total: personas.length,
      activos: personas.filter((p) => p.estado === "activo").length,
      suspension: personas.filter((p) => p.estado === "suspension").length,
      bajasDelMes: personas.filter((p) => {
        if (!p.fecha_baja) return false;
        const fecha = new Date(`${p.fecha_baja}T00:00:00`);
        return !Number.isNaN(fecha.getTime()) && fecha >= inicioMes;
      }).length,
    };
  }, [personas]);

  // Una persona puede tener más de una asignación vigente en paralelo (ya visto en
  // FichaDepartamentoPage/FichaPuestoPage) -- se agrupa por persona_id acumulando todos sus
  // puestos/departamentos/áreas, sin duplicar cuando dos puestos comparten departamento o área.
  const asignacionesPorPersona = useMemo(() => {
    const mapa = new Map<string, DatosAsignacionPersona>();
    for (const a of asignaciones) {
      const existente = mapa.get(a.persona_id);
      if (existente) {
        if (!existente.puestoIds.includes(a.puesto_id)) {
          existente.puestos.push(a.nombre_puesto);
          existente.puestoIds.push(a.puesto_id);
        }
        if (!existente.departamentos.includes(a.nombre_departamento)) {
          existente.departamentos.push(a.nombre_departamento);
        }
        if (!existente.areas.includes(a.nombre_area)) {
          existente.areas.push(a.nombre_area);
        }
      } else {
        mapa.set(a.persona_id, {
          puestos: [a.nombre_puesto],
          puestoIds: [a.puesto_id],
          departamentos: [a.nombre_departamento],
          areas: [a.nombre_area],
        });
      }
    }
    return mapa;
  }, [asignaciones]);

  const opcionesPuesto = useMemo(() => {
    const mapa = new Map<string, string>();
    for (const a of asignaciones) mapa.set(a.puesto_id, a.nombre_puesto);
    return [...mapa.entries()].sort((a, b) => a[1].localeCompare(b[1]));
  }, [asignaciones]);

  const opcionesDepartamento = useMemo(
    () => [...new Set(asignaciones.map((a) => a.nombre_departamento))].sort((a, b) => a.localeCompare(b)),
    [asignaciones],
  );

  const opcionesArea = useMemo(
    () => [...new Set(asignaciones.map((a) => a.nombre_area))].sort((a, b) => a.localeCompare(b)),
    [asignaciones],
  );

  const filtradas = useMemo(() => {
    const consulta = normalizar(busqueda.trim());
    return personas.filter((persona) => {
      const coincideBusqueda =
        !consulta ||
        normalizar(`${persona.primer_nombre} ${persona.apellido_paterno}`).includes(consulta);
      const coincideEstado = !filtroEstado || persona.estado === filtroEstado;
      const datosAsignacion = asignacionesPorPersona.get(persona.id);
      const coincidePuesto = !filtroPuesto || Boolean(datosAsignacion?.puestoIds.includes(filtroPuesto));
      const coincideDepartamento =
        !filtroDepartamento || Boolean(datosAsignacion?.departamentos.includes(filtroDepartamento));
      const coincideArea = !filtroArea || Boolean(datosAsignacion?.areas.includes(filtroArea));
      return coincideBusqueda && coincideEstado && coincidePuesto && coincideDepartamento && coincideArea;
    });
  }, [
    personas,
    busqueda,
    filtroEstado,
    filtroPuesto,
    filtroDepartamento,
    filtroArea,
    asignacionesPorPersona,
  ]);

  function celdaAsignacion(valores: string[] | undefined): string {
    if (estadoAsignaciones !== "listo") return "—";
    if (!valores || valores.length === 0) return "Sin asignar";
    return valores.join(", ");
  }

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <strong>Personas</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Directorio de personas</h1>
            <p className="subtitulo-pagina">
              Padrón vigente de la plantilla y su situación laboral actual.
            </p>
          </div>
          <a href="/personas/nueva" className="boton-con-icono boton-primario">
            <Plus size={16} aria-hidden="true" />
            Agregar persona
          </a>
        </div>

        <div className="banda-metricas">
          <div className="metrica">
            <span className="etiqueta-metrica">Total en padrón</span>
            <strong>{metricas.total}</strong>
            <span className="detalle-metrica">personas registradas</span>
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
              <span className="punto punto--aviso" aria-hidden="true" />
              Suspensión temporal
            </span>
            <strong>{metricas.suspension}</strong>
          </div>
          <div className="metrica">
            <span className="etiqueta-metrica">
              <span className="punto punto--peligro" aria-hidden="true" />
              Bajas del mes
            </span>
            <strong>{metricas.bajasDelMes}</strong>
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
            <option value="suspension">Suspensión</option>
            <option value="baja_definitiva">Baja</option>
          </select>
          <div className="grupo-filtros-secundarios">
            <select
              value={filtroPuesto}
              onChange={(evento) => setFiltroPuesto(evento.target.value)}
              aria-label="Filtrar por puesto"
              disabled={estadoAsignaciones !== "listo"}
            >
              <option value="">Puesto: Todos</option>
              {opcionesPuesto.map(([id, nombre]) => (
                <option key={id} value={id}>
                  {nombre}
                </option>
              ))}
            </select>
            <select
              value={filtroDepartamento}
              onChange={(evento) => setFiltroDepartamento(evento.target.value)}
              aria-label="Filtrar por departamento"
              disabled={estadoAsignaciones !== "listo"}
            >
              <option value="">Departamento: Todos</option>
              {opcionesDepartamento.map((nombre) => (
                <option key={nombre} value={nombre}>
                  {nombre}
                </option>
              ))}
            </select>
            <select
              value={filtroArea}
              onChange={(evento) => setFiltroArea(evento.target.value)}
              aria-label="Filtrar por área"
              disabled={estadoAsignaciones !== "listo"}
            >
              <option value="">Área: Todas</option>
              {opcionesArea.map((nombre) => (
                <option key={nombre} value={nombre}>
                  {nombre}
                </option>
              ))}
            </select>
          </div>
        </div>

        {estadoAsignaciones === "sin_permiso" && (
          <small className="ayuda-campo">
            No tienes permiso para ver el puesto/departamento/área asignados a cada persona.
          </small>
        )}
        {estadoAsignaciones === "error" && (
          <small className="ayuda-campo">No se pudo cargar la asignación de puestos.</small>
        )}

        {estadoCarga === "cargando" && (
          <p className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando personas…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar el directorio
            </strong>
            <p>Ocurrió un problema al consultar el padrón.</p>
            <button type="button" onClick={cargar}>
              Reintentar
            </button>
          </div>
        )}

        {estadoCarga === "listo" && filtradas.length === 0 && (
          <div className="estado-vacio">
            <Users size={28} aria-hidden="true" />
            <p>No hay personas registradas o tu cuenta no tiene acceso al padrón.</p>
          </div>
        )}

        {estadoCarga === "listo" && filtradas.length > 0 && (
          <>
            <div className="tabla-desplazable">
              <table>
                <thead>
                  <tr>
                    <th>Persona</th>
                    <th>Puesto</th>
                    <th>Departamento</th>
                    <th>Área</th>
                    <th>Ingreso</th>
                    <th>Estado</th>
                  </tr>
                </thead>
                <tbody>
                  {filtradas.map((persona) => {
                    const datosAsignacion = asignacionesPorPersona.get(persona.id);
                    return (
                      <tr key={persona.id}>
                        <td>
                          <a href={`/personas/${persona.id}`} className="persona-celda">
                            <span className="avatar-iniciales">{inicialesDe(persona)}</span>
                            {persona.primer_nombre} {persona.apellido_paterno}
                          </a>
                        </td>
                        <td>{celdaAsignacion(datosAsignacion?.puestos)}</td>
                        <td>{celdaAsignacion(datosAsignacion?.departamentos)}</td>
                        <td>{celdaAsignacion(datosAsignacion?.areas)}</td>
                        <td>{formatearFecha(persona.fecha_ingreso)}</td>
                        <td>
                          <span className={`insignia ${CLASE_ESTADO[persona.estado] ?? "insignia--neutra"}`}>
                            {ETIQUETA_ESTADO[persona.estado] ?? persona.estado}
                          </span>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            <p className="pie-tabla">
              Mostrando {filtradas.length} de {personas.length} personas
            </p>
          </>
        )}
      </div>
    </AppShell>
  );
}
