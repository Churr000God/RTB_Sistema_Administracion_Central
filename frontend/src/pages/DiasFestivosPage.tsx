import { Fragment, type FormEvent, useEffect, useMemo, useState } from "react";
import {
  AlertCircle,
  CalendarDays,
  ChevronLeft,
  ChevronRight,
  Loader2,
  Search,
  Trash2,
} from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { aFechaISO, grillaDelMes, semanaDeDias, type DiaGrilla } from "../lib/calendario";
import { Badge } from "../components/Badge";
import { Button } from "../components/Button";
import { Input } from "../components/Input";

type Festivo = {
  id: number;
  fecha: string; // "YYYY-MM-DD"
  nombre: string;
};

type EstadoCarga = "cargando" | "listo" | "error";

type VistaPrincipal = "lista" | "calendario";
type VistaCalendario = "mensual" | "semanal";

const MESES = [
  "Enero",
  "Febrero",
  "Marzo",
  "Abril",
  "Mayo",
  "Junio",
  "Julio",
  "Agosto",
  "Septiembre",
  "Octubre",
  "Noviembre",
  "Diciembre",
];

const DIAS_SEMANA_CORTOS = ["Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"];

function formatearFecha(fecha: string): string {
  const valor = new Date(`${fecha}T00:00:00`);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" });
}

function formatearDiaSemana(fecha: string): string {
  const valor = new Date(`${fecha}T00:00:00`);
  if (Number.isNaN(valor.getTime())) return "—";
  const nombre = valor.toLocaleDateString("es-MX", { weekday: "long" });
  return nombre.charAt(0).toUpperCase() + nombre.slice(1);
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

export function DiasFestivosPage() {
  const [festivos, setFestivos] = useState<Festivo[]>([]);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");

  const [errorAlta, setErrorAlta] = useState<string | null>(null);
  const [guardando, setGuardando] = useState(false);
  const [formKey, setFormKey] = useState(0);

  const [vistaPrincipal, setVistaPrincipal] = useState<VistaPrincipal>("lista");
  const [vistaCalendario, setVistaCalendario] = useState<VistaCalendario>("mensual");
  const [ancla, setAncla] = useState(() => new Date());

  const [busqueda, setBusqueda] = useState("");
  const [filtroAnio, setFiltroAnio] = useState("");
  const [filtroMes, setFiltroMes] = useState("");
  const [filtroFecha, setFiltroFecha] = useState("");

  const [pendienteEliminarId, setPendienteEliminarId] = useState<number | null>(null);
  const [errorEliminar, setErrorEliminar] = useState<string | null>(null);
  const [eliminando, setEliminando] = useState(false);

  function cargar() {
    setEstadoCarga("cargando");
    apiFetch("/api/dias-festivos")
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datos: Festivo[]) => {
        setFestivos(datos);
        setEstadoCarga("listo");
      })
      .catch(() => setEstadoCarga("error"));
  }

  useEffect(cargar, []);

  const hoyIso = useMemo(() => aFechaISO(new Date()), []);

  const festivosPorFecha = useMemo(() => {
    const mapa = new Map<string, Festivo>();
    for (const f of festivos) mapa.set(f.fecha, f);
    return mapa;
  }, [festivos]);

  const aniosDisponibles = useMemo(
    () => [...new Set(festivos.map((f) => f.fecha.slice(0, 4)))].sort((a, b) => b.localeCompare(a)),
    [festivos],
  );

  const hayFiltrosActivos = !!(busqueda || filtroAnio || filtroMes || filtroFecha);

  const festivosFiltrados = useMemo(() => {
    const consulta = busqueda.trim().toLowerCase();
    return festivos.filter((f) => {
      const coincideBusqueda = !consulta || f.nombre.toLowerCase().includes(consulta);
      const coincideAnio = !filtroAnio || f.fecha.slice(0, 4) === filtroAnio;
      const coincideMes = !filtroMes || f.fecha.slice(5, 7) === filtroMes;
      const coincideFecha = !filtroFecha || f.fecha === filtroFecha;
      return coincideBusqueda && coincideAnio && coincideMes && coincideFecha;
    });
  }, [festivos, busqueda, filtroAnio, filtroMes, filtroFecha]);

  function limpiarFiltros() {
    setBusqueda("");
    setFiltroAnio("");
    setFiltroMes("");
    setFiltroFecha("");
  }

  async function handleAlta(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setErrorAlta(null);
    setGuardando(true);
    const f = new FormData(evento.currentTarget);
    try {
      const respuesta = await apiFetch("/api/dias-festivos", {
        method: "POST",
        body: JSON.stringify({ fecha: String(f.get("fecha")), nombre: String(f.get("nombre")) }),
      });
      if (!respuesta.ok) {
        setErrorAlta(await mensajeDeError(respuesta, "No se pudo registrar el día festivo."));
        return;
      }
      setFormKey((anterior) => anterior + 1);
      cargar();
    } catch {
      setErrorAlta("No se pudo registrar el día festivo. Revisa tu conexión e intenta de nuevo.");
    } finally {
      setGuardando(false);
    }
  }

  function solicitarEliminar(id: number) {
    setPendienteEliminarId(id);
    setErrorEliminar(null);
  }

  function cancelarEliminar() {
    setPendienteEliminarId(null);
    setErrorEliminar(null);
  }

  async function confirmarEliminar() {
    if (pendienteEliminarId === null) return;
    setEliminando(true);
    setErrorEliminar(null);
    try {
      const respuesta = await apiFetch(`/api/dias-festivos/${pendienteEliminarId}`, {
        method: "DELETE",
      });
      if (!respuesta.ok) {
        // 422 (fecha ya no es futura) u otro rechazo — la fila pudo envejecer entre la carga y
        // el click. Se muestra el motivo sin cerrar la confirmación: cerrarla en silencio
        // dejaría a la persona sin saber por qué no se borró.
        setErrorEliminar(await mensajeDeError(respuesta, "No se pudo eliminar el día festivo."));
        return;
      }
      setPendienteEliminarId(null);
      cargar();
    } catch {
      setErrorEliminar("No se pudo eliminar el día festivo. Revisa tu conexión e intenta de nuevo.");
    } finally {
      setEliminando(false);
    }
  }

  function irAnterior() {
    if (vistaCalendario === "mensual") {
      setAncla((a) => new Date(a.getFullYear(), a.getMonth() - 1, 1));
    } else {
      setAncla((a) => {
        const d = new Date(a);
        d.setDate(d.getDate() - 7);
        return d;
      });
    }
  }

  function irSiguiente() {
    if (vistaCalendario === "mensual") {
      setAncla((a) => new Date(a.getFullYear(), a.getMonth() + 1, 1));
    } else {
      setAncla((a) => {
        const d = new Date(a);
        d.setDate(d.getDate() + 7);
        return d;
      });
    }
  }

  function irHoy() {
    setAncla(new Date());
  }

  const semanasDelMes = useMemo(() => grillaDelMes(ancla), [ancla]);
  const diasDeLaSemana = useMemo(() => semanaDeDias(ancla), [ancla]);

  const tituloPeriodo =
    vistaCalendario === "mensual"
      ? `${MESES[ancla.getMonth()]} ${ancla.getFullYear()}`
      : `${formatearFecha(diasDeLaSemana[0].fecha)} – ${formatearFecha(diasDeLaSemana[6].fecha)}`;

  function renderCeldaMes(dia: DiaGrilla) {
    const festivo = festivosPorFecha.get(dia.fecha);
    const clases = [
      "celda-mes",
      !dia.delMesActual && "celda-mes--adyacente",
      festivo && "celda-mes--festivo",
      dia.fecha === hoyIso && "celda-mes--hoy",
    ]
      .filter(Boolean)
      .join(" ");
    return (
      <div key={dia.fecha} className={clases}>
        <span className="numero-dia">{dia.diaDelMes}</span>
        {festivo && <span className="nombre-festivo">{festivo.nombre}</span>}
      </div>
    );
  }

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <strong>Días festivos</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Días festivos</h1>
            <p className="subtitulo-pagina">
              Catálogo de días festivos — se usan para excluirlos de faltas y horas extra.
            </p>
          </div>
        </div>

        <div className="tarjeta-resumen">
          <h3>Registrar día festivo</h3>
          <form key={formKey} onSubmit={handleAlta} className="fieldset-formulario">
            <div className="rejilla-campos">
              <Input id="fecha-festivo" name="fecha" label="Fecha" type="date" required />
              <Input id="nombre-festivo" name="nombre" label="Nombre" type="text" maxLength={100} required />
            </div>
            {errorAlta && <p role="alert">{errorAlta}</p>}
            <div className="botonera">
              <Button type="submit" variante="primario" cargando={guardando} textoCargando="Guardando…">
                Registrar día festivo
              </Button>
            </div>
          </form>
        </div>

        <div className="pestanas" role="tablist" aria-label="Vista de días festivos">
          <button
            type="button"
            role="tab"
            aria-selected={vistaPrincipal === "lista"}
            className={`pestana${vistaPrincipal === "lista" ? " pestana--activa" : ""}`}
            onClick={() => setVistaPrincipal("lista")}
          >
            Lista
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={vistaPrincipal === "calendario"}
            className={`pestana${vistaPrincipal === "calendario" ? " pestana--activa" : ""}`}
            onClick={() => setVistaPrincipal("calendario")}
          >
            Calendario
          </button>
        </div>

        {estadoCarga === "cargando" && (
          <p className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar el catálogo de días festivos
            </strong>
            <button type="button" onClick={cargar}>
              Reintentar
            </button>
          </div>
        )}

        {estadoCarga === "listo" && festivos.length === 0 && (
          <div className="estado-vacio">
            <CalendarDays size={28} aria-hidden="true" />
            <p>No hay días festivos registrados.</p>
          </div>
        )}

        {estadoCarga === "listo" && festivos.length > 0 && vistaPrincipal === "lista" && (
          <div role="tabpanel">
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
              <div className="grupo-filtros-secundarios">
                <select
                  value={filtroAnio}
                  onChange={(evento) => setFiltroAnio(evento.target.value)}
                  aria-label="Filtrar por año"
                >
                  <option value="">Año: Todos</option>
                  {aniosDisponibles.map((anio) => (
                    <option key={anio} value={anio}>
                      {anio}
                    </option>
                  ))}
                </select>
                <select
                  value={filtroMes}
                  onChange={(evento) => setFiltroMes(evento.target.value)}
                  aria-label="Filtrar por mes"
                >
                  <option value="">Mes: Todos</option>
                  {MESES.map((nombreMes, indice) => (
                    <option key={nombreMes} value={String(indice + 1).padStart(2, "0")}>
                      {nombreMes}
                    </option>
                  ))}
                </select>
                <Input
                  id="filtro-fecha-exacta"
                  label="Fecha exacta"
                  type="date"
                  value={filtroFecha}
                  onChange={(evento) => setFiltroFecha(evento.target.value)}
                />
              </div>
            </div>

            {festivosFiltrados.length === 0 ? (
              <div className="estado-vacio">
                <p>Ningún día festivo coincide con los filtros.</p>
                <Button type="button" onClick={limpiarFiltros}>
                  Limpiar filtros
                </Button>
              </div>
            ) : (
              <div className="tabla-desplazable">
                <table>
                  <thead>
                    <tr>
                      <th>Fecha</th>
                      <th>Día de semana</th>
                      <th>Nombre</th>
                      <th>Estado</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    {festivosFiltrados.map((festivo) => {
                      const esPasadoOhoy = festivo.fecha <= hoyIso;
                      return (
                        <Fragment key={festivo.id}>
                          <tr>
                            <td>{formatearFecha(festivo.fecha)}</td>
                            <td>{formatearDiaSemana(festivo.fecha)}</td>
                            <td>{festivo.nombre}</td>
                            <td>
                              <Badge
                                variante={
                                  festivo.fecha === hoyIso
                                    ? "aviso"
                                    : festivo.fecha > hoyIso
                                      ? "exito"
                                      : "neutra"
                                }
                              >
                                {festivo.fecha === hoyIso
                                  ? "Hoy"
                                  : festivo.fecha > hoyIso
                                    ? "Futuro"
                                    : "Pasado"}
                              </Badge>
                            </td>
                            <td>
                              <button
                                type="button"
                                className="boton-con-icono"
                                disabled={esPasadoOhoy}
                                title={
                                  esPasadoOhoy
                                    ? "No podés eliminar un día festivo de hoy o del pasado."
                                    : undefined
                                }
                                aria-label={
                                  esPasadoOhoy
                                    ? `No podés eliminar ${festivo.nombre}: es de hoy o del pasado`
                                    : `Eliminar ${festivo.nombre}`
                                }
                                onClick={() => solicitarEliminar(festivo.id)}
                              >
                                <Trash2 size={14} aria-hidden="true" />
                                Eliminar
                              </button>
                            </td>
                          </tr>
                          {pendienteEliminarId === festivo.id && (
                            <tr>
                              <td colSpan={5}>
                                <p role="alert">
                                  ¿Eliminar el día festivo <strong>{festivo.nombre}</strong> (
                                  {formatearFecha(festivo.fecha)})? Esta acción no se puede deshacer.
                                </p>
                                {errorEliminar && <p role="alert">{errorEliminar}</p>}
                                <div className="botonera">
                                  <Button type="button" onClick={cancelarEliminar}>
                                    Cancelar
                                  </Button>
                                  <Button
                                    type="button"
                                    variante="primario"
                                    cargando={eliminando}
                                    textoCargando="Eliminando…"
                                    onClick={confirmarEliminar}
                                  >
                                    Sí, eliminar
                                  </Button>
                                </div>
                              </td>
                            </tr>
                          )}
                        </Fragment>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        )}

        {estadoCarga === "listo" && festivos.length > 0 && vistaPrincipal === "calendario" && (
          <div role="tabpanel">
            <div className="pestanas" role="tablist" aria-label="Vista de calendario">
              <button
                type="button"
                role="tab"
                aria-selected={vistaCalendario === "mensual"}
                className={`pestana${vistaCalendario === "mensual" ? " pestana--activa" : ""}`}
                onClick={() => setVistaCalendario("mensual")}
              >
                Mensual
              </button>
              <button
                type="button"
                role="tab"
                aria-selected={vistaCalendario === "semanal"}
                className={`pestana${vistaCalendario === "semanal" ? " pestana--activa" : ""}`}
                onClick={() => setVistaCalendario("semanal")}
              >
                Semanal
              </button>
            </div>

            <div className="cabecera-calendario">
              <h3 className="titulo-periodo-calendario">{tituloPeriodo}</h3>
              <div className="botonera">
                <button type="button" className="boton-con-icono" onClick={irAnterior} aria-label="Anterior">
                  <ChevronLeft size={16} aria-hidden="true" />
                </button>
                <button type="button" className="boton-con-icono" onClick={irHoy}>
                  Hoy
                </button>
                <button type="button" className="boton-con-icono" onClick={irSiguiente} aria-label="Siguiente">
                  <ChevronRight size={16} aria-hidden="true" />
                </button>
              </div>
            </div>

            {vistaCalendario === "mensual" ? (
              <div className="calendario-mensual">
                {DIAS_SEMANA_CORTOS.map((nombre) => (
                  <div key={nombre} className="cabecera-dia-mes">
                    {nombre}
                  </div>
                ))}
                {semanasDelMes.flat().map((dia) => renderCeldaMes(dia))}
              </div>
            ) : (
              <div className="calendario-semanal">
                {diasDeLaSemana.map((dia, indice) => {
                  const festivo = festivosPorFecha.get(dia.fecha);
                  const clases = [
                    "dia-calendario",
                    festivo && "dia-calendario--festivo",
                    dia.fecha === hoyIso && "dia-calendario--hoy",
                  ]
                    .filter(Boolean)
                    .join(" ");
                  return (
                    <div key={dia.fecha} className={clases}>
                      <span className="nombre-dia">{DIAS_SEMANA_CORTOS[indice]}</span>
                      <span className="horario-dia">{dia.diaDelMes}</span>
                      {festivo && <span className="comida-dia">{festivo.nombre}</span>}
                    </div>
                  );
                })}
              </div>
            )}
          </div>
        )}
      </div>
    </AppShell>
  );
}
