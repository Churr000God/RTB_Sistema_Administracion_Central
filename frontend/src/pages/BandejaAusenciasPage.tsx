import { Fragment, useEffect, useRef, useState } from "react";
import { AlertCircle, Loader2, Search } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { CATALOGO_TIPO_AUSENCIA, etiquetaTipoAusencia, type TipoAusencia } from "../lib/tiposAusencia";
import { Badge } from "../components/Badge";
import { Button } from "../components/Button";
import { Input } from "../components/Input";

// Debounce del buscador de persona: mismo criterio que DiasPage/TramosPage — es el único filtro
// sin precedente de "dispara al toque".
const DEBOUNCE_BUSQUEDA_MS = 300;
const LIMITE = 20;
const COLUMNAS = 8;

type TipoAusenciaReclasificable = "vacaciones" | "permiso_con_goce" | "permiso_sin_goce" | "incapacidad";

type EstadoAutorizacion = "pendiente" | "autorizada" | "rechazada";

type Ausencia = {
  id: number;
  persona_id: string;
  persona_nombre: string | null;
  tipo_de_ausencia: string;
  fecha_inicio: string;
  fecha_fin: string;
  estado_autorizacion: EstadoAutorizacion;
  documento_ref: string | null;
  aprobador_id: string | null;
  aprobador_nombre: string | null;
  motivo: string | null;
  decidido_en: string | null;
};

type RespuestaAusencias = { total: number; ausencias: Ausencia[] };

type EstadoCarga = "cargando" | "listo" | "error";

type Orden = "fecha_desc" | "fecha_asc";

const OPCIONES_RECLASIFICACION: { valor: TipoAusenciaReclasificable; etiqueta: string }[] = [
  { valor: "vacaciones", etiqueta: "Vacaciones" },
  { valor: "permiso_con_goce", etiqueta: "Permiso con goce" },
  { valor: "permiso_sin_goce", etiqueta: "Permiso sin goce" },
  { valor: "incapacidad", etiqueta: "Incapacidad" },
];

function formatearFecha(fecha: string): string {
  // fecha_inicio/fecha_fin son DATE (sin hora) — new Date("2026-09-10") a secas lo interpreta
  // como medianoche UTC, y en cualquier timezone detrás de UTC (ej. America/Mexico_City)
  // muestra el día anterior. Forzar hora local evita el corrimiento.
  const valor = new Date(`${fecha}T00:00:00`);
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

export function BandejaAusenciasPage() {
  const [ausencias, setAusencias] = useState<Ausencia[]>([]);
  const [total, setTotal] = useState(0);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [busqueda, setBusqueda] = useState("");
  const [busquedaDebounced, setBusquedaDebounced] = useState("");
  const [desde, setDesde] = useState("");
  const [hasta, setHasta] = useState("");
  const [filtroTipo, setFiltroTipo] = useState<TipoAusencia | "">("");
  const [filtroEstado, setFiltroEstado] = useState<EstadoAutorizacion | "">("");
  const [orden, setOrden] = useState<Orden>("fecha_desc");
  const [desplazamiento, setDesplazamiento] = useState(0);
  // Mismo propósito que DiasPage/TramosPage: con debounce + filtros encadenados las respuestas
  // pueden llegar fuera de orden — sólo la más nueva gana.
  const cargaEnCursoRef = useRef(0);

  const [pendienteResolverId, setPendienteResolverId] = useState<number | null>(null);
  const [decision, setDecision] = useState<"autorizada" | "rechazada" | "">("");
  const [tipoElegido, setTipoElegido] = useState<TipoAusenciaReclasificable | "">("");
  const [motivo, setMotivo] = useState("");
  const [resolviendo, setResolviendo] = useState(false);
  const [errorResolver, setErrorResolver] = useState<string | null>(null);

  useEffect(() => {
    const id = setTimeout(() => {
      setBusquedaDebounced(busqueda.trim());
      setDesplazamiento(0);
    }, DEBOUNCE_BUSQUEDA_MS);
    return () => clearTimeout(id);
  }, [busqueda]);

  function cargar() {
    const params = new URLSearchParams();
    if (busquedaDebounced) params.set("busqueda_persona", busquedaDebounced);
    if (desde) params.set("desde", desde);
    if (hasta) params.set("hasta", hasta);
    if (filtroTipo) params.set("tipo", filtroTipo);
    if (filtroEstado) params.set("estado", filtroEstado);
    params.set("orden", orden);
    params.set("limite", String(LIMITE));
    params.set("desplazamiento", String(desplazamiento));

    const idCarga = ++cargaEnCursoRef.current;
    setEstadoCarga("cargando");
    apiFetch(`/api/ausencias?${params.toString()}`)
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datos: RespuestaAusencias) => {
        if (idCarga !== cargaEnCursoRef.current) return;
        setAusencias(datos.ausencias);
        setTotal(datos.total);
        setEstadoCarga("listo");
      })
      .catch(() => {
        if (idCarga !== cargaEnCursoRef.current) return;
        setEstadoCarga("error");
      });
  }

  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(cargar, [busquedaDebounced, desde, hasta, filtroTipo, filtroEstado, orden, desplazamiento]);

  const hayFiltrosActivos = !!(busqueda || desde || hasta || filtroTipo || filtroEstado);

  function limpiarFiltros() {
    setBusqueda("");
    setBusquedaDebounced("");
    setDesde("");
    setHasta("");
    setFiltroTipo("");
    setFiltroEstado("");
    setDesplazamiento(0);
  }

  function solicitarResolver(id: number) {
    setPendienteResolverId(id);
    setDecision("");
    setTipoElegido("");
    setMotivo("");
    setErrorResolver(null);
  }

  function cancelarResolver() {
    setPendienteResolverId(null);
    setDecision("");
    setTipoElegido("");
    setMotivo("");
    setErrorResolver(null);
  }

  const puedeConfirmar = decision !== "" && (decision === "rechazada" || tipoElegido !== "");

  async function confirmarResolver() {
    if (pendienteResolverId === null || !puedeConfirmar) return;
    setResolviendo(true);
    setErrorResolver(null);
    try {
      const respuesta = await apiFetch(`/api/ausencias/${pendienteResolverId}/resolver`, {
        method: "POST",
        body: JSON.stringify({
          decision,
          tipo_de_ausencia: decision === "autorizada" ? tipoElegido : undefined,
          motivo: motivo || undefined,
        }),
      });
      if (!respuesta.ok) {
        // La fila pudo envejecer entre la carga y el click (ya resuelta por alguien más) — se
        // muestra el motivo sin cerrar la confirmación, mismo criterio que Días/DiasFestivos.
        setErrorResolver(await mensajeDeError(respuesta, "No se pudo resolver la ausencia."));
        return;
      }
      setPendienteResolverId(null);
      setDecision("");
      setTipoElegido("");
      setMotivo("");
      cargar();
    } catch {
      setErrorResolver("No se pudo resolver la ausencia. Revisa tu conexión e intenta de nuevo.");
    } finally {
      setResolviendo(false);
    }
  }

  function badgeEstado(estado: EstadoAutorizacion) {
    // "rechazada" muestra la misma etiqueta que "pendiente" a propósito -- es cosmético en esta
    // pantalla, el dato real sigue siendo consultable (columna Estado real vía el filtro).
    if (estado === "autorizada") return <Badge variante="exito">Autorizada</Badge>;
    return <Badge variante="aviso">Pendiente</Badge>;
  }

  const paginaActual = Math.floor(desplazamiento / LIMITE) + 1;
  const hayPaginaAnterior = desplazamiento > 0;
  const hayPaginaSiguiente = desplazamiento + LIMITE < total;

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <strong>Ausencias</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Ausencias</h1>
            <p className="subtitulo-pagina">
              Consulta de todas las ausencias, no sólo las pendientes. Resolver una falta la
              reclasifica (autorizar) o la deja como falta definitiva (rechazar).
            </p>
          </div>
        </div>

        <ul className="leyenda-estados leyenda-estados--grilla">
          {(Object.keys(CATALOGO_TIPO_AUSENCIA) as TipoAusencia[]).map((tipo) => (
            <li key={tipo}>
              <span className="punto" aria-hidden="true" />
              <span>
                <strong>{CATALOGO_TIPO_AUSENCIA[tipo].etiqueta}</strong>
                <span className="descripcion">{CATALOGO_TIPO_AUSENCIA[tipo].descripcion}</span>
              </span>
            </li>
          ))}
        </ul>

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
            <Input
              id="filtro-ausencia-desde"
              label="Desde"
              type="date"
              value={desde}
              onChange={(evento) => {
                setDesde(evento.target.value);
                setDesplazamiento(0);
              }}
            />
            <Input
              id="filtro-ausencia-hasta"
              label="Hasta"
              type="date"
              value={hasta}
              onChange={(evento) => {
                setHasta(evento.target.value);
                setDesplazamiento(0);
              }}
            />
            <select
              value={filtroTipo}
              onChange={(evento) => {
                setFiltroTipo(evento.target.value as TipoAusencia | "");
                setDesplazamiento(0);
              }}
              aria-label="Filtrar por tipo"
            >
              <option value="">Tipo: Todos</option>
              {(Object.keys(CATALOGO_TIPO_AUSENCIA) as TipoAusencia[]).map((tipo) => (
                <option key={tipo} value={tipo}>
                  {CATALOGO_TIPO_AUSENCIA[tipo].etiqueta}
                </option>
              ))}
            </select>
            <select
              value={filtroEstado}
              onChange={(evento) => {
                setFiltroEstado(evento.target.value as EstadoAutorizacion | "");
                setDesplazamiento(0);
              }}
              aria-label="Filtrar por estado"
            >
              <option value="">Estado: Todos</option>
              <option value="pendiente">Pendiente</option>
              <option value="autorizada">Autorizada</option>
              <option value="rechazada">Rechazada</option>
            </select>
            <select
              value={orden}
              onChange={(evento) => {
                setOrden(evento.target.value as Orden);
                setDesplazamiento(0);
              }}
              aria-label="Ordenar por"
            >
              <option value="fecha_desc">Fecha: más recientes primero</option>
              <option value="fecha_asc">Fecha: más antiguas primero</option>
            </select>
            {hayFiltrosActivos && (
              <Button type="button" onClick={limpiarFiltros}>
                Limpiar filtros
              </Button>
            )}
          </div>
        </div>

        {estadoCarga === "cargando" && (
          <p className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando ausencias…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar la bandeja de ausencias
            </strong>
            <p>Ocurrió un problema al consultar las ausencias.</p>
            <Button type="button" onClick={cargar}>
              Reintentar
            </Button>
          </div>
        )}

        {estadoCarga === "listo" && ausencias.length === 0 && (
          <div className="estado-vacio">
            <p>No hay ausencias que coincidan con la búsqueda.</p>
          </div>
        )}

        {estadoCarga === "listo" && ausencias.length > 0 && (
          <>
            <div className="tabla-desplazable">
              <table>
                <thead>
                  <tr>
                    <th>Persona</th>
                    <th>Tipo</th>
                    <th>Fecha inicio</th>
                    <th>Fecha fin</th>
                    <th>Estado</th>
                    <th>Documento</th>
                    <th>Aprobado por</th>
                    <th>Acción</th>
                  </tr>
                </thead>
                <tbody>
                  {ausencias.map((ausencia) => (
                    <Fragment key={ausencia.id}>
                      <tr>
                        <td>{ausencia.persona_nombre ?? "—"}</td>
                        <td>
                          <Badge variante="neutra">{etiquetaTipoAusencia(ausencia.tipo_de_ausencia)}</Badge>
                        </td>
                        <td>{formatearFecha(ausencia.fecha_inicio)}</td>
                        <td>{formatearFecha(ausencia.fecha_fin)}</td>
                        <td>{badgeEstado(ausencia.estado_autorizacion)}</td>
                        <td>{ausencia.documento_ref ?? "—"}</td>
                        <td>
                          {ausencia.aprobador_nombre ?? "—"}
                          {ausencia.motivo && <div className="ayuda-campo">{ausencia.motivo}</div>}
                        </td>
                        <td>
                          {ausencia.estado_autorizacion === "pendiente" && (
                            <Button
                              type="button"
                              aria-label={`Resolver — ${ausencia.persona_nombre ?? "sin nombre"}, ${formatearFecha(ausencia.fecha_inicio)}`}
                              onClick={() => solicitarResolver(ausencia.id)}
                            >
                              Resolver
                            </Button>
                          )}
                        </td>
                      </tr>
                      {pendienteResolverId === ausencia.id && (
                        <tr>
                          <td colSpan={COLUMNAS}>
                            <p role="alert">
                              Resolver la ausencia de <strong>{ausencia.persona_nombre ?? "—"}</strong>{" "}
                              ({formatearFecha(ausencia.fecha_inicio)} – {formatearFecha(ausencia.fecha_fin)})
                            </p>
                            <fieldset className="fieldset-formulario">
                              <legend>Decisión</legend>
                              <label>
                                <input
                                  type="radio"
                                  name={`decision-${ausencia.id}`}
                                  value="autorizada"
                                  checked={decision === "autorizada"}
                                  onChange={() => setDecision("autorizada")}
                                />
                                Autorizar
                              </label>
                              <label>
                                <input
                                  type="radio"
                                  name={`decision-${ausencia.id}`}
                                  value="rechazada"
                                  checked={decision === "rechazada"}
                                  onChange={() => setDecision("rechazada")}
                                />
                                Rechazar (queda como falta)
                              </label>
                            </fieldset>
                            {decision === "autorizada" && (
                              <div className="campo">
                                <label htmlFor={`tipo-${ausencia.id}`}>Reclasificar a</label>
                                <select
                                  id={`tipo-${ausencia.id}`}
                                  value={tipoElegido}
                                  onChange={(evento) =>
                                    setTipoElegido(evento.target.value as TipoAusenciaReclasificable | "")
                                  }
                                >
                                  <option value="">Selecciona un tipo</option>
                                  {OPCIONES_RECLASIFICACION.map(({ valor, etiqueta }) => (
                                    <option key={valor} value={valor}>
                                      {etiqueta}
                                    </option>
                                  ))}
                                </select>
                              </div>
                            )}
                            <div className="campo">
                              <label htmlFor={`motivo-${ausencia.id}`}>Motivo (opcional)</label>
                              <textarea
                                id={`motivo-${ausencia.id}`}
                                value={motivo}
                                onChange={(evento) => setMotivo(evento.target.value)}
                                rows={2}
                              />
                            </div>
                            {errorResolver && <p role="alert">{errorResolver}</p>}
                            <div className="botonera">
                              <Button type="button" onClick={cancelarResolver}>
                                Cancelar
                              </Button>
                              <Button
                                type="button"
                                variante="primario"
                                cargando={resolviendo}
                                textoCargando="Confirmando…"
                                disabled={!puedeConfirmar}
                                onClick={confirmarResolver}
                              >
                                Confirmar
                              </Button>
                            </div>
                          </td>
                        </tr>
                      )}
                    </Fragment>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="pie-tabla">
              Mostrando {ausencias.length} de {total} ausencias
            </p>
            <div className="botonera">
              <Button
                type="button"
                onClick={() => setDesplazamiento((actual) => Math.max(0, actual - LIMITE))}
                disabled={!hayPaginaAnterior}
              >
                Anterior
              </Button>
              <span className="ayuda-campo">Página {paginaActual}</span>
              <Button
                type="button"
                onClick={() => setDesplazamiento((actual) => actual + LIMITE)}
                disabled={!hayPaginaSiguiente}
              >
                Siguiente
              </Button>
            </div>
          </>
        )}
      </div>
    </AppShell>
  );
}
