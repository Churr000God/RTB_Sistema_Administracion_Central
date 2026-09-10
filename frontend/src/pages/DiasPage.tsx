import { Fragment, useEffect, useRef, useState } from "react";
import { AlertCircle, AlertTriangle, ChevronDown, ChevronRight, Loader2, Search } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Badge } from "../components/Badge";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { Input } from "../components/Input";

// Debounce del buscador de persona: mismo criterio que TramosPage — es el único filtro sin
// precedente de "dispara al toque".
const DEBOUNCE_BUSQUEDA_MS = 300;
const LIMITE = 20;
const COLUMNAS = 12;

type EstadoDia = "abierto" | "cerrado" | "bloqueado" | "revisado";

type Dia = {
  id: number;
  fecha: string;
  persona_id: string;
  persona_nombre: string | null;
  estado: EstadoDia;
  horas_totales: number | null;
  origen: "automatico_confianza" | "ausencia_autorizada" | null;
  primera_marca: string | null;
  ultima_marca: string | null;
  alerta_entrada: "retardo" | "entrada_anticipada" | null;
  alerta_salida: "salida_anticipada" | "salida_tardia" | null;
  excepciones_pendientes: number;
};

type RespuestaDias = { total: number; dias: Dia[] };

type EstadoCarga = "cargando" | "listo" | "error";

type Orden = "fecha_desc" | "fecha_asc" | "horas_desc" | "horas_asc";

// Flujo de la fila de confirmación de "Marcar como revisado": arranca en "calcular" (sólo el
// botón "Calcular tiempo total"), pasa a "bloqueada" si el día tiene una marca huérfana (nada de
// input ni Confirmar — hay que corregir esa marca primero) o a "editable" si no (el input de
// horas aparece precargado con el cálculo, pero sigue siendo editable).
type FaseConfirmacion = "calcular" | "calculando" | "bloqueada" | "editable";

type Previsualizacion = { horas_calculadas: number; tiene_huerfana_sin_pareja: boolean };

type PersonaPendienteCorte = {
  persona_id: string;
  persona_nombre: string | null;
  fechas_faltantes: string[];
};

type RespuestaPendientesCorte = {
  periodo_desde: string;
  periodo_hasta: string;
  personas: PersonaPendienteCorte[];
};

function formatearFecha(fecha: string): string {
  const valor = new Date(`${fecha}T00:00:00`);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" });
}

function formatearHora(fecha: string | null): string {
  if (!fecha) return "—";
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleTimeString("es-MX", { hour: "2-digit", minute: "2-digit" });
}

function formatearHorasTotales(horas: number | null): string {
  if (horas === null) return "—";
  const totalMinutos = Math.round(horas * 60);
  const h = Math.floor(totalMinutos / 60);
  const m = totalMinutos % 60;
  return `${h}h ${m}m`;
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

// Mismo patrón literal que TramosPage.tsx: "abierto"/"cerrado" son el ciclo de vida normal del
// día, sin badge — sólo "bloqueado" (SCJ-DEC-06) y "revisado" son desvíos con aviso visual.
const ETIQUETA_ESTADO: Partial<Record<EstadoDia, string>> = {
  bloqueado: "Bloqueado — necesita revisión",
  revisado: "Revisado",
};

const VARIANTE_ESTADO: Partial<Record<EstadoDia, "peligro" | "exito">> = {
  bloqueado: "peligro",
  revisado: "exito",
};

const ETIQUETA_ESTADO_FILTRO: Record<EstadoDia, string> = {
  abierto: "Abierto",
  cerrado: "Cerrado",
  bloqueado: "Bloqueado",
  revisado: "Revisado",
};

const ETIQUETA_ORIGEN: Record<"automatico_confianza" | "ausencia_autorizada", string> = {
  automatico_confianza: "Automático (confianza)",
  ausencia_autorizada: "Ausencia autorizada",
};

const ETIQUETA_ALERTA_ENTRADA: Record<"retardo" | "entrada_anticipada", string> = {
  retardo: "Retardo",
  entrada_anticipada: "Entrada anticipada",
};

const ETIQUETA_ALERTA_SALIDA: Record<"salida_anticipada" | "salida_tardia", string> = {
  salida_anticipada: "Salida anticipada",
  salida_tardia: "Salida tardía",
};

export function DiasPage() {
  const [dias, setDias] = useState<Dia[]>([]);
  const [total, setTotal] = useState(0);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [busqueda, setBusqueda] = useState("");
  const [busquedaDebounced, setBusquedaDebounced] = useState("");
  const [desde, setDesde] = useState("");
  const [hasta, setHasta] = useState("");
  const [filtroEstado, setFiltroEstado] = useState<EstadoDia | "">("");
  const [orden, setOrden] = useState<Orden>("fecha_desc");
  const [desplazamiento, setDesplazamiento] = useState(0);
  // Mismo propósito que TramosPage: con debounce + filtros encadenados las respuestas pueden
  // llegar fuera de orden — sólo la más nueva gana.
  const cargaEnCursoRef = useRef(0);

  const [pendienteRevisarId, setPendienteRevisarId] = useState<number | null>(null);
  const [errorRevisar, setErrorRevisar] = useState<string | null>(null);
  const [revisando, setRevisando] = useState(false);
  const [valorHoras, setValorHoras] = useState("");
  const [faseConfirmacion, setFaseConfirmacion] = useState<FaseConfirmacion>("calcular");

  // Fetch propio, independiente de la paginación/filtros de la tabla principal -- mismo criterio
  // que otros datos auxiliares de esta familia de pantallas (ej. el ledger de Banco de Horas).
  // Puramente informativo (no bloquea nada): si falla, el banner simplemente no aparece.
  const [pendientesCorte, setPendientesCorte] = useState<RespuestaPendientesCorte | null>(null);
  const [bannerAbierto, setBannerAbierto] = useState(true);

  useEffect(() => {
    apiFetch("/api/dias/pendientes-corte-quincenal")
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datos: RespuestaPendientesCorte) => setPendientesCorte(datos))
      .catch(() => {
        // silencioso a propósito -- ver comentario arriba.
      });
  }, []);

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
    if (filtroEstado) params.set("estado", filtroEstado);
    params.set("orden", orden);
    params.set("limite", String(LIMITE));
    params.set("desplazamiento", String(desplazamiento));

    const idCarga = ++cargaEnCursoRef.current;
    setEstadoCarga("cargando");
    apiFetch(`/api/dias?${params.toString()}`)
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datos: RespuestaDias) => {
        if (idCarga !== cargaEnCursoRef.current) return;
        setDias(datos.dias);
        setTotal(datos.total);
        setEstadoCarga("listo");
      })
      .catch(() => {
        if (idCarga !== cargaEnCursoRef.current) return;
        setEstadoCarga("error");
      });
  }

  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(cargar, [busquedaDebounced, desde, hasta, filtroEstado, orden, desplazamiento]);

  const hayFiltrosActivos = !!(busqueda || desde || hasta || filtroEstado);

  function limpiarFiltros() {
    setBusqueda("");
    setBusquedaDebounced("");
    setDesde("");
    setHasta("");
    setFiltroEstado("");
    setDesplazamiento(0);
  }

  function solicitarRevisar(id: number) {
    setPendienteRevisarId(id);
    setErrorRevisar(null);
    setValorHoras("");
    setFaseConfirmacion("calcular");
  }

  function cancelarRevisar() {
    setPendienteRevisarId(null);
    setErrorRevisar(null);
    setValorHoras("");
    setFaseConfirmacion("calcular");
  }

  async function calcularTiempo() {
    if (pendienteRevisarId === null) return;
    setFaseConfirmacion("calculando");
    setErrorRevisar(null);
    try {
      const respuesta = await apiFetch(`/api/dias/${pendienteRevisarId}/previsualizar-tramos`);
      if (!respuesta.ok) {
        setErrorRevisar(await mensajeDeError(respuesta, "No se pudo calcular el tiempo total."));
        setFaseConfirmacion("calcular");
        return;
      }
      const datos: Previsualizacion = await respuesta.json();
      if (datos.tiene_huerfana_sin_pareja) {
        setFaseConfirmacion("bloqueada");
        return;
      }
      setValorHoras(datos.horas_calculadas.toFixed(2));
      setFaseConfirmacion("editable");
    } catch {
      setErrorRevisar("No se pudo calcular el tiempo total. Revisa tu conexión e intenta de nuevo.");
      setFaseConfirmacion("calcular");
    }
  }

  const horasNumero = Number(valorHoras);
  const horasValidas = valorHoras !== "" && !Number.isNaN(horasNumero) && horasNumero >= 0 && horasNumero <= 24;

  async function confirmarRevisar() {
    if (pendienteRevisarId === null || !horasValidas) return;
    setRevisando(true);
    setErrorRevisar(null);
    try {
      const respuesta = await apiFetch(`/api/dias/${pendienteRevisarId}/revisar`, {
        method: "POST",
        body: JSON.stringify({ horas_totales: horasNumero }),
      });
      if (!respuesta.ok) {
        // 404 (día ya no existe) / 409 (ya no está bloqueado, o SCJ09 -- alguien agregó una
        // marca entre calcular y confirmar) / 422 (horas fuera de rango que el form no atrapó) —
        // la fila pudo envejecer entre la carga y el click. Se muestra el motivo sin cerrar la
        // confirmación, mismo criterio que DiasFestivosPage al eliminar: cerrarla en silencio
        // dejaría a la persona sin saber por qué no se marcó como revisado.
        setErrorRevisar(await mensajeDeError(respuesta, "No se pudo marcar el día como revisado."));
        return;
      }
      setPendienteRevisarId(null);
      setValorHoras("");
      setFaseConfirmacion("calcular");
      cargar();
    } catch {
      setErrorRevisar("No se pudo marcar el día como revisado. Revisa tu conexión e intenta de nuevo.");
    } finally {
      setRevisando(false);
    }
  }

  const paginaActual = Math.floor(desplazamiento / LIMITE) + 1;
  const hayPaginaAnterior = desplazamiento > 0;
  const hayPaginaSiguiente = desplazamiento + LIMITE < total;

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <strong>Días</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Días</h1>
            <p className="subtitulo-pagina">
              Consulta por persona y fecha, con la primera y última marca efectivas (con
              corrección aplicada) y sus alertas de horario. Un día bloqueado necesita revisión
              manual — es la única transición que se puede hacer a mano.
            </p>
          </div>
        </div>

        {pendientesCorte && pendientesCorte.personas.length > 0 && (
          <Card>
            <button
              type="button"
              className="boton-con-icono"
              style={{ justifyContent: "space-between", width: "100%", textAlign: "left" }}
              aria-expanded={bannerAbierto}
              onClick={() => setBannerAbierto((anterior) => !anterior)}
            >
              <span className="boton-con-icono" style={{ justifyContent: "flex-start" }}>
                <AlertTriangle size={16} aria-hidden="true" />
                {pendientesCorte.personas.length} persona(s) con días sin marcar en el periodo
                actual ({formatearFecha(pendientesCorte.periodo_desde)}–
                {formatearFecha(pendientesCorte.periodo_hasta)}) — van a bloquear el corte
                quincenal si no se resuelven antes del corte.
              </span>
              {bannerAbierto ? (
                <ChevronDown size={16} aria-hidden="true" />
              ) : (
                <ChevronRight size={16} aria-hidden="true" />
              )}
            </button>
            {bannerAbierto && (
              <ul style={{ marginTop: "0.75rem", marginBottom: 0 }}>
                {pendientesCorte.personas.map((persona) => (
                  <li key={persona.persona_id}>
                    {persona.persona_nombre ?? "—"}:{" "}
                    {persona.fechas_faltantes.map((fecha) => formatearFecha(fecha)).join(", ")}
                  </li>
                ))}
              </ul>
            )}
          </Card>
        )}

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
              id="filtro-dia-desde"
              label="Desde"
              type="date"
              value={desde}
              onChange={(evento) => {
                setDesde(evento.target.value);
                setDesplazamiento(0);
              }}
            />
            <Input
              id="filtro-dia-hasta"
              label="Hasta"
              type="date"
              value={hasta}
              onChange={(evento) => {
                setHasta(evento.target.value);
                setDesplazamiento(0);
              }}
            />
            <select
              value={filtroEstado}
              onChange={(evento) => {
                setFiltroEstado(evento.target.value as EstadoDia | "");
                setDesplazamiento(0);
              }}
              aria-label="Filtrar por estado"
            >
              <option value="">Estado: Todos</option>
              {(Object.keys(ETIQUETA_ESTADO_FILTRO) as EstadoDia[]).map((estado) => (
                <option key={estado} value={estado}>
                  {ETIQUETA_ESTADO_FILTRO[estado]}
                </option>
              ))}
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
              <option value="horas_desc">Horas totales: mayor primero</option>
              <option value="horas_asc">Horas totales: menor primero</option>
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
            Cargando días…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudieron cargar los días
            </strong>
            <p>Ocurrió un problema al consultar los días.</p>
            <Button type="button" onClick={cargar}>
              Reintentar
            </Button>
          </div>
        )}

        {estadoCarga === "listo" && dias.length === 0 && (
          <div className="estado-vacio">
            <p>No hay días que coincidan con la búsqueda.</p>
          </div>
        )}

        {estadoCarga === "listo" && dias.length > 0 && (
          <>
            <div className="tabla-desplazable">
              <table>
                <thead>
                  <tr>
                    <th>Día</th>
                    <th>Persona</th>
                    <th>Fecha</th>
                    <th>Estado</th>
                    <th>Horas totales</th>
                    <th>Origen</th>
                    <th>Primera marca</th>
                    <th>Última marca</th>
                    <th>Alerta entrada</th>
                    <th>Alerta salida</th>
                    <th>Excepciones</th>
                    <th>Acción</th>
                  </tr>
                </thead>
                <tbody>
                  {dias.map((dia) => (
                    <Fragment key={dia.id}>
                      <tr>
                        <td>{dia.id}</td>
                        <td>{dia.persona_nombre ?? "—"}</td>
                        <td>{formatearFecha(dia.fecha)}</td>
                        <td>
                          {(() => {
                            const variante = VARIANTE_ESTADO[dia.estado];
                            return variante ? (
                              <Badge variante={variante}>{ETIQUETA_ESTADO[dia.estado]}</Badge>
                            ) : (
                              "—"
                            );
                          })()}
                        </td>
                        <td>{formatearHorasTotales(dia.horas_totales)}</td>
                        <td>{dia.origen ? ETIQUETA_ORIGEN[dia.origen] : "—"}</td>
                        <td>{formatearHora(dia.primera_marca)}</td>
                        <td>{formatearHora(dia.ultima_marca)}</td>
                        <td>
                          {dia.alerta_entrada ? (
                            <Badge variante="aviso">{ETIQUETA_ALERTA_ENTRADA[dia.alerta_entrada]}</Badge>
                          ) : (
                            "—"
                          )}
                        </td>
                        <td>
                          {dia.alerta_salida ? (
                            <Badge variante="aviso">{ETIQUETA_ALERTA_SALIDA[dia.alerta_salida]}</Badge>
                          ) : (
                            "—"
                          )}
                        </td>
                        <td>
                          {dia.excepciones_pendientes > 0 ? (
                            <Badge variante="aviso">{dia.excepciones_pendientes} pendiente(s)</Badge>
                          ) : (
                            "—"
                          )}
                        </td>
                        <td>
                          {dia.estado === "bloqueado" && (
                            <Button
                              type="button"
                              aria-label={`Marcar como revisado — ${dia.persona_nombre ?? "sin nombre"}, ${formatearFecha(dia.fecha)}`}
                              onClick={() => solicitarRevisar(dia.id)}
                            >
                              Marcar como revisado
                            </Button>
                          )}
                        </td>
                      </tr>
                      {pendienteRevisarId === dia.id && (
                        <tr>
                          <td colSpan={COLUMNAS}>
                            <p role="alert">
                              ¿Marcar como revisado el día de <strong>{dia.persona_nombre ?? "—"}</strong>{" "}
                              ({formatearFecha(dia.fecha)})?
                            </p>
                            {faseConfirmacion === "bloqueada" && (
                              <p role="alert">
                                Este día tiene una marca sin pareja — corregí la marca faltante o
                                usá captura manual antes de poder revisar.
                              </p>
                            )}
                            {faseConfirmacion === "editable" && (
                              <Input
                                id={`horas-revisar-${dia.id}`}
                                label="Horas trabajadas"
                                type="number"
                                min={0}
                                max={24}
                                step={0.25}
                                required
                                value={valorHoras}
                                onChange={(evento) => setValorHoras(evento.target.value)}
                              />
                            )}
                            {errorRevisar && <p role="alert">{errorRevisar}</p>}
                            <div className="botonera">
                              <Button type="button" onClick={cancelarRevisar}>
                                Cancelar
                              </Button>
                              {(faseConfirmacion === "calcular" || faseConfirmacion === "calculando") && (
                                <Button
                                  type="button"
                                  cargando={faseConfirmacion === "calculando"}
                                  textoCargando="Calculando…"
                                  onClick={calcularTiempo}
                                >
                                  Calcular tiempo total
                                </Button>
                              )}
                              {faseConfirmacion === "editable" && (
                                <Button
                                  type="button"
                                  variante="primario"
                                  cargando={revisando}
                                  textoCargando="Confirmando…"
                                  disabled={!horasValidas}
                                  onClick={confirmarRevisar}
                                >
                                  Confirmar
                                </Button>
                              )}
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
              Mostrando {dias.length} de {total} días
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
