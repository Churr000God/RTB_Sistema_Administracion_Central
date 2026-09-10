import { Fragment, useEffect, useRef, useState } from "react";
import { AlertCircle, ChevronDown, ChevronRight, Loader2, Search } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import {
  TRAMOS_ANTIGUEDAD,
  etiquetaTramoAntiguedad,
  type TramoAntiguedad,
} from "../lib/tramosAntiguedad";
import { Badge } from "../components/Badge";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { Input } from "../components/Input";

// Debounce del buscador de persona: mismo criterio que TramosPage/DiasPage — es el único filtro
// sin precedente de "dispara al toque".
const DEBOUNCE_BUSQUEDA_MS = 300;
const LIMITE = 20;
const COLUMNAS = 8;

// Ventana por defecto mientras el primer GET no resolvió — sólo afecta la etiqueta de los
// selectores/columnas durante el spinner inicial; en cuanto llega `resumen.ventana_meses` real
// (hoy 6, pero es un parámetro del sistema editable) se usa ese valor.
const VENTANA_MESES_DEFECTO = 6;

type Orden = "monto_desc" | "monto_asc" | "antiguedad_desc" | "antiguedad_asc";

// Eje de alerta por MAGNITUD de la deuda (% de la jornada semanal) -- distinto del eje de
// antigüedad (TramoAntiguedad, tramosAntiguedad.ts) y sin relación con Alertas de retardo.
type NivelAlerta = "sin_alerta" | "aviso" | "escalamiento";

type TopEnDeuda = {
  persona_id: string;
  persona_nombre: string | null;
  monto: number;
  meses_antiguedad_max: number;
};

type Resumen = {
  total_personas: number;
  en_deuda: number;
  sin_deuda: number;
  horas_adeudadas: number;
  horas_fuera_ventana: number;
  personas_fuera_ventana: number;
  personas_corte_pendiente: number;
  personas_en_aviso: number;
  personas_en_escalamiento: number;
  aviso_pct: number;
  escalamiento_pct: number;
  ventana_meses: number;
  top_en_deuda: TopEnDeuda[];
};

type SaldoBancoHoras = {
  persona_id: string;
  persona_nombre: string | null;
  monto: number;
  vivo_desde: string | null;
  // null cuando es una fila sintética -- persona con corte pendiente que nunca tuvo fila real en
  // tiempo.banco_de_horas (nunca se le generó/actualizó un saldo).
  actualizado_en: string | null;
  horas_reciente: number;
  horas_media: number;
  horas_fuera_ventana: number;
  meses_antiguedad_max: number;
  conciliado: boolean;
  corte_pendiente: boolean;
  // null cuando la persona no tiene jornada normal/flexible vigente (ej. de_confianza) -- ahí no
  // hay base contra la que medir el % de la jornada semanal.
  jornada_semanal_horas: number | null;
  porcentaje_jornada_semanal: number | null;
  nivel_alerta: NivelAlerta | null;
};

type RespuestaBancoHoras = { total: number; resumen: Resumen; saldos: SaldoBancoHoras[] };

type TipoMovimiento = "generado_quincena" | "cubrir" | "arrastrar" | "descontar" | "condonar";

type Movimiento = {
  id: number;
  creado_en: string;
  tipo: TipoMovimiento;
  monto: number;
  motivo: string | null;
  autor_nombre: string | null;
  saldo_corrido: number;
  vivo: boolean;
};

type TipoMovimientoManual = "arrastrar" | "descontar" | "condonar";

type EstadoCarga = "cargando" | "listo" | "error";

type EstadoLedger = { estado: EstadoCarga; movimientos: Movimiento[] };

const ETIQUETA_TIPO_MOVIMIENTO: Record<TipoMovimiento, string> = {
  generado_quincena: "Generado (quincena)",
  cubrir: "Cubrió falta",
  arrastrar: "Arrastre",
  descontar: "Descuento",
  condonar: "Condonación",
};

function formatearHoras(monto: number): string {
  return `${monto.toFixed(2)} h`;
}

function formatearHorasConSigno(monto: number): string {
  return `${monto > 0 ? "+" : ""}${formatearHoras(monto)}`;
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

const ETIQUETA_NIVEL_ALERTA: Record<NivelAlerta, string> = {
  sin_alerta: "Sin alerta",
  aviso: "Aviso",
  escalamiento: "Escalamiento",
};

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

export function BancoDeHorasPage() {
  const [datos, setDatos] = useState<RespuestaBancoHoras | null>(null);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [busqueda, setBusqueda] = useState("");
  const [busquedaDebounced, setBusquedaDebounced] = useState("");
  const [filtroTramo, setFiltroTramo] = useState<TramoAntiguedad | "">("");
  const [filtroNivel, setFiltroNivel] = useState<NivelAlerta | "">("");
  const [orden, setOrden] = useState<Orden>("monto_desc");
  const [desplazamiento, setDesplazamiento] = useState(0);
  // Mismo propósito que TramosPage/DiasPage: con debounce + filtros encadenados las respuestas
  // pueden llegar fuera de orden — sólo la más nueva gana.
  const cargaEnCursoRef = useRef(0);

  // Fila expandida del ledger: sólo una a la vez (molde AsignarJornadaPage), cacheada por
  // persona_id para no refetchear al reabrir/cerrar la misma persona.
  const [filaExpandidaId, setFilaExpandidaId] = useState<string | null>(null);
  const [ledgerCache, setLedgerCache] = useState<Record<string, EstadoLedger>>({});

  // Movimiento de saldo manual (resolver deuda con ventana_meses+ de antigüedad) -- un solo
  // formulario, porque sólo puede haber una fila expandida a la vez.
  const [movTipo, setMovTipo] = useState<TipoMovimientoManual>("arrastrar");
  const [movMonto, setMovMonto] = useState("");
  const [movMotivo, setMovMotivo] = useState("");
  const [movEnviando, setMovEnviando] = useState(false);
  const [movError, setMovError] = useState<string | null>(null);

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
    if (filtroTramo) params.set("tramo_antiguedad", filtroTramo);
    if (filtroNivel) params.set("nivel_alerta", filtroNivel);
    params.set("orden", orden);
    params.set("limite", String(LIMITE));
    params.set("desplazamiento", String(desplazamiento));

    const idCarga = ++cargaEnCursoRef.current;
    setEstadoCarga("cargando");
    apiFetch(`/api/banco-de-horas?${params.toString()}`)
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datosRespuesta: RespuestaBancoHoras) => {
        if (idCarga !== cargaEnCursoRef.current) return;
        setDatos(datosRespuesta);
        setEstadoCarga("listo");
      })
      .catch(() => {
        if (idCarga !== cargaEnCursoRef.current) return;
        setEstadoCarga("error");
      });
  }

  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(cargar, [busquedaDebounced, filtroTramo, filtroNivel, orden, desplazamiento]);

  const hayFiltrosActivos = !!(busqueda || filtroTramo || filtroNivel);

  function limpiarFiltros() {
    setBusqueda("");
    setBusquedaDebounced("");
    setFiltroTramo("");
    setFiltroNivel("");
    setDesplazamiento(0);
  }

  async function cargarLedger(id: string) {
    setLedgerCache((anterior) => ({ ...anterior, [id]: { estado: "cargando", movimientos: [] } }));
    try {
      const respuesta = await apiFetch(`/api/banco-de-horas/${id}/movimientos`);
      if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
      const datosLedger: { total: number; movimientos: Movimiento[] } = await respuesta.json();
      setLedgerCache((anterior) => ({
        ...anterior,
        [id]: { estado: "listo", movimientos: datosLedger.movimientos },
      }));
    } catch {
      setLedgerCache((anterior) => ({ ...anterior, [id]: { estado: "error", movimientos: [] } }));
    }
  }

  function reiniciarFormularioMovimiento(saldo: SaldoBancoHoras | undefined) {
    setMovTipo("arrastrar");
    setMovMonto(saldo && saldo.horas_fuera_ventana > 0 ? saldo.horas_fuera_ventana.toFixed(2) : "");
    setMovMotivo("");
    setMovError(null);
  }

  function alternarFila(id: string) {
    if (filaExpandidaId === id) {
      setFilaExpandidaId(null);
      return;
    }
    setFilaExpandidaId(id);
    reiniciarFormularioMovimiento(datos?.saldos.find((s) => s.persona_id === id));
    if (ledgerCache[id]) return; // ya cacheada -- no refetch al reabrir la misma persona
    cargarLedger(id);
  }

  const movMontoNumero = Number(movMonto);
  const movMontoValido = movMonto !== "" && !Number.isNaN(movMontoNumero) && movMontoNumero > 0;
  const puedeConfirmarMovimiento = movMontoValido && movMotivo.trim() !== "";

  async function confirmarMovimiento(id: string) {
    if (!puedeConfirmarMovimiento) return;
    setMovEnviando(true);
    setMovError(null);
    try {
      const respuesta = await apiFetch(`/api/banco-de-horas/${id}/movimientos`, {
        method: "POST",
        body: JSON.stringify({ tipo: movTipo, monto: movMontoNumero, motivo: movMotivo.trim() }),
      });
      if (!respuesta.ok) {
        // 422 (monto <= 0 o excede la porción fuera de ventana) / 409 (excede el saldo total,
        // backstop) / 404 (persona sin banco) — se muestra el motivo sin cerrar el formulario ni
        // perder lo que la persona ya escribió, mismo criterio que el resto del proyecto.
        setMovError(await mensajeDeError(respuesta, "No se pudo aplicar el movimiento."));
        return;
      }
      const datosLedger: { total: number; movimientos: Movimiento[] } = await respuesta.json();
      setLedgerCache((anterior) => ({
        ...anterior,
        [id]: { estado: "listo", movimientos: datosLedger.movimientos },
      }));
      // El saldo/desglose por antigüedad de esta persona en la tabla principal cambió -- hace
      // falta refrescar `cargar()`, no sólo el ledger. reiniciarFormularioMovimiento(undefined)
      // limpia los campos en vez de reusar el máximo viejo (quedaría obsoleto hasta que
      // `cargar()` resuelva).
      reiniciarFormularioMovimiento(undefined);
      cargar();
    } catch {
      setMovError("No se pudo aplicar el movimiento. Revisa tu conexión e intenta de nuevo.");
    } finally {
      setMovEnviando(false);
    }
  }

  const ventanaMeses = datos?.resumen.ventana_meses ?? VENTANA_MESES_DEFECTO;
  const montoMaximoTopDeuda = datos?.resumen.top_en_deuda[0]?.monto ?? 0;
  const sinDeudaPagina = datos?.saldos.filter((s) => s.monto === 0) ?? [];

  const paginaActual = Math.floor(desplazamiento / LIMITE) + 1;
  const hayPaginaAnterior = desplazamiento > 0;
  const hayPaginaSiguiente = datos != null && desplazamiento + LIMITE < datos.total;

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <strong>Banco de horas</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Banco de horas</h1>
            <p className="subtitulo-pagina">
              Deuda de horas acumulada por persona. No existe saldo a favor — sólo deuda o cero.
            </p>
          </div>
        </div>

        {datos && (
          <div className="banda-metricas">
            <div className="metrica">
              <span className="etiqueta-metrica">Personas con saldo</span>
              <strong>{datos.resumen.total_personas}</strong>
            </div>
            <div className="metrica">
              <span className="etiqueta-metrica">
                <span className="punto punto--peligro" aria-hidden="true" />
                En deuda
              </span>
              <strong>{datos.resumen.en_deuda}</strong>
              <span className="detalle-metrica">
                {formatearHoras(datos.resumen.horas_adeudadas)} acumuladas
              </span>
            </div>
            <div className="metrica">
              <span className="etiqueta-metrica">
                <span className="punto punto--exito" aria-hidden="true" />
                Sin deuda
              </span>
              <strong>{datos.resumen.sin_deuda}</strong>
            </div>
            <div className="metrica">
              <span className="etiqueta-metrica">
                <span className="punto punto--peligro" aria-hidden="true" />
                Fuera de ventana
              </span>
              <strong>{datos.resumen.personas_fuera_ventana}</strong>
              <span className="detalle-metrica">
                {formatearHoras(datos.resumen.horas_fuera_ventana)}
              </span>
            </div>
            <div className="metrica">
              <span className="etiqueta-metrica">
                <span className="punto punto--aviso" aria-hidden="true" />
                Corte pendiente
              </span>
              <strong>{datos.resumen.personas_corte_pendiente}</strong>
            </div>
            <div className="metrica">
              <span className="etiqueta-metrica">
                <span className="punto punto--aviso" aria-hidden="true" />
                En aviso
              </span>
              <strong>{datos.resumen.personas_en_aviso}</strong>
              <span className="detalle-metrica">≥ {datos.resumen.aviso_pct}% de la jornada semanal</span>
            </div>
            <div className="metrica">
              <span className="etiqueta-metrica">
                <span className="punto punto--peligro" aria-hidden="true" />
                En escalamiento
              </span>
              <strong>{datos.resumen.personas_en_escalamiento}</strong>
              <span className="detalle-metrica">
                ≥ {datos.resumen.escalamiento_pct}% de la jornada semanal
              </span>
            </div>
          </div>
        )}

        {datos && (
          <div className="rejilla-tarjetas">
            <Card>
              <h3>Top en deuda</h3>
              {datos.resumen.top_en_deuda.length === 0 ? (
                <p>Nadie tiene horas en deuda ahora mismo.</p>
              ) : (
                <div className="grafica-barras">
                  {datos.resumen.top_en_deuda.map((persona) => (
                    <div className="fila-grafica-barras" key={persona.persona_id}>
                      <span className="etiqueta-barra">{persona.persona_nombre ?? "—"}</span>
                      <div className="pista-barra">
                        <div
                          className="relleno-barra"
                          style={{ transform: `scaleX(${persona.monto / montoMaximoTopDeuda})` }}
                        />
                      </div>
                      <span className="valor-barra">{formatearHoras(persona.monto)}</span>
                    </div>
                  ))}
                </div>
              )}
              {datos.resumen.en_deuda > datos.resumen.top_en_deuda.length && (
                <p className="pie-tabla">
                  y {datos.resumen.en_deuda - datos.resumen.top_en_deuda.length} persona(s) más en
                  deuda
                </p>
              )}
            </Card>

            <Card>
              <h3>Sin deuda</h3>
              {sinDeudaPagina.length === 0 ? (
                <p>Nadie sin deuda entre las personas visibles.</p>
              ) : (
                <div className="lista-chips-personas">
                  {sinDeudaPagina.map((saldo) => (
                    <Badge variante="exito" key={saldo.persona_id}>
                      {saldo.persona_nombre ?? "—"}
                    </Badge>
                  ))}
                </div>
              )}
            </Card>
          </div>
        )}

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
              value={filtroTramo}
              onChange={(evento) => {
                setFiltroTramo(evento.target.value as TramoAntiguedad | "");
                setDesplazamiento(0);
              }}
              aria-label="Filtrar por tramo de antigüedad"
            >
              <option value="">Tramo: Todos</option>
              {TRAMOS_ANTIGUEDAD.map((tramo) => (
                <option key={tramo} value={tramo}>
                  {etiquetaTramoAntiguedad(tramo, ventanaMeses)}
                </option>
              ))}
            </select>
            <select
              value={filtroNivel}
              onChange={(evento) => {
                setFiltroNivel(evento.target.value as NivelAlerta | "");
                setDesplazamiento(0);
              }}
              aria-label="Filtrar por nivel de alerta"
            >
              <option value="">Nivel: Todos</option>
              <option value="sin_alerta">Sin alerta</option>
              <option value="aviso">Aviso</option>
              <option value="escalamiento">Escalamiento</option>
            </select>
            <select
              value={orden}
              onChange={(evento) => {
                setOrden(evento.target.value as Orden);
                setDesplazamiento(0);
              }}
              aria-label="Ordenar por"
            >
              <option value="monto_desc">Saldo: mayor primero</option>
              <option value="monto_asc">Saldo: menor primero</option>
              <option value="antiguedad_desc">Antigüedad: mayor primero</option>
              <option value="antiguedad_asc">Antigüedad: menor primero</option>
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
            Cargando saldos…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar el banco de horas
            </strong>
            <p>Ocurrió un problema al consultar los saldos.</p>
            <Button type="button" onClick={cargar}>
              Reintentar
            </Button>
          </div>
        )}

        {estadoCarga === "listo" && datos && datos.saldos.length === 0 && (
          <div className="estado-vacio">
            <p>No hay saldos que coincidan con la búsqueda.</p>
          </div>
        )}

        {estadoCarga === "listo" && datos && datos.saldos.length > 0 && (
          <>
            <div className="tabla-desplazable">
              <table>
                <thead>
                  <tr>
                    <th>Persona</th>
                    <th>Saldo</th>
                    <th>Nivel</th>
                    <th>{etiquetaTramoAntiguedad("reciente", ventanaMeses)}</th>
                    <th>{etiquetaTramoAntiguedad("media", ventanaMeses)}</th>
                    <th>{etiquetaTramoAntiguedad("fuera_ventana", ventanaMeses)}</th>
                    <th>En deuda desde</th>
                    <th>Actualizado</th>
                  </tr>
                </thead>
                <tbody>
                  {datos.saldos.map((saldo) => {
                    const expandida = filaExpandidaId === saldo.persona_id;
                    const ledger = ledgerCache[saldo.persona_id];
                    return (
                      <Fragment key={saldo.persona_id}>
                        <tr className="seleccionable" onClick={() => alternarFila(saldo.persona_id)}>
                          <td>
                            <span className="boton-con-icono" style={{ justifyContent: "flex-start" }}>
                              {expandida ? (
                                <ChevronDown size={16} aria-hidden="true" />
                              ) : (
                                <ChevronRight size={16} aria-hidden="true" />
                              )}
                              {saldo.persona_nombre ?? "—"}
                            </span>
                            {!saldo.conciliado && (
                              <div className="ayuda-campo">
                                <Badge
                                  variante="aviso"
                                  title="El desglose por tramos no reconcilia con el saldo real -- se muestra una aproximación."
                                >
                                  Aproximado
                                </Badge>
                              </div>
                            )}
                          </td>
                          <td>
                            <Badge variante={saldo.monto > 0 ? "peligro" : "exito"}>
                              {formatearHoras(saldo.monto)} {saldo.monto > 0 ? "en deuda" : "sin deuda"}
                            </Badge>
                          </td>
                          <td>
                            {saldo.nivel_alerta === "escalamiento" && (
                              <Badge variante="peligro">{ETIQUETA_NIVEL_ALERTA.escalamiento}</Badge>
                            )}
                            {saldo.nivel_alerta === "aviso" && (
                              <Badge variante="aviso">{ETIQUETA_NIVEL_ALERTA.aviso}</Badge>
                            )}
                            {(saldo.nivel_alerta === "sin_alerta" || saldo.nivel_alerta === null) && "—"}
                          </td>
                          <td>{formatearHoras(saldo.horas_reciente)}</td>
                          <td>{formatearHoras(saldo.horas_media)}</td>
                          <td>
                            {saldo.horas_fuera_ventana > 0 ? (
                              <Badge variante="peligro">{formatearHoras(saldo.horas_fuera_ventana)}</Badge>
                            ) : (
                              "—"
                            )}
                          </td>
                          <td>{formatearFechaHora(saldo.vivo_desde)}</td>
                          <td>
                            {formatearFechaHora(saldo.actualizado_en)}
                            {saldo.corte_pendiente && (
                              <div className="ayuda-campo">
                                <Badge
                                  variante="aviso"
                                  title="El corte quincenal del último periodo ya vencido todavía no se aplicó para esta persona -- puede estar bloqueado por un día sin marcar, o simplemente no haberse disparado todavía."
                                >
                                  Corte pendiente
                                </Badge>
                              </div>
                            )}
                          </td>
                        </tr>
                        {expandida && (
                          <tr>
                            <td colSpan={COLUMNAS}>
                              <p className="ayuda-campo">
                                {saldo.jornada_semanal_horas != null &&
                                saldo.porcentaje_jornada_semanal != null
                                  ? `${formatearHoras(saldo.monto)} de deuda · ${saldo.porcentaje_jornada_semanal}% de una jornada semanal de ${saldo.jornada_semanal_horas.toFixed(2)} h`
                                  : "Sin jornada normal/flexible vigente -- no se puede medir el % de la jornada semanal."}
                              </p>
                              {saldo.horas_fuera_ventana > 0 && (
                                <div className="fieldset-formulario" style={{ marginBottom: "1.25rem" }}>
                                  <p style={{ margin: 0 }}>
                                    <strong>
                                      Resolver deuda con {etiquetaTramoAntiguedad("fuera_ventana", ventanaMeses)}{" "}
                                      de antigüedad
                                    </strong>{" "}
                                    — {formatearHoras(saldo.horas_fuera_ventana)} disponibles.
                                  </p>
                                  <div className="rejilla-campos">
                                    <div className="campo">
                                      <label htmlFor={`mov-tipo-${saldo.persona_id}`}>Acción</label>
                                      <select
                                        id={`mov-tipo-${saldo.persona_id}`}
                                        value={movTipo}
                                        onChange={(evento) =>
                                          setMovTipo(evento.target.value as TipoMovimientoManual)
                                        }
                                      >
                                        <option value="arrastrar">Renovar antigüedad</option>
                                        <option value="descontar">Descontar (nómina)</option>
                                        <option value="condonar">Condonar</option>
                                      </select>
                                    </div>
                                    <Input
                                      id={`mov-monto-${saldo.persona_id}`}
                                      label="Monto (horas)"
                                      type="number"
                                      min={0.01}
                                      max={saldo.horas_fuera_ventana}
                                      step={0.25}
                                      required
                                      value={movMonto}
                                      onChange={(evento) => setMovMonto(evento.target.value)}
                                    />
                                  </div>
                                  <div className="campo">
                                    <label htmlFor={`mov-motivo-${saldo.persona_id}`}>Motivo</label>
                                    <textarea
                                      id={`mov-motivo-${saldo.persona_id}`}
                                      value={movMotivo}
                                      onChange={(evento) => setMovMotivo(evento.target.value)}
                                      rows={2}
                                    />
                                  </div>
                                  {movError && <p role="alert">{movError}</p>}
                                  <div className="botonera">
                                    <Button
                                      type="button"
                                      onClick={() => reiniciarFormularioMovimiento(saldo)}
                                    >
                                      Cancelar
                                    </Button>
                                    <Button
                                      type="button"
                                      variante="primario"
                                      cargando={movEnviando}
                                      textoCargando="Aplicando…"
                                      disabled={!puedeConfirmarMovimiento}
                                      onClick={() => confirmarMovimiento(saldo.persona_id)}
                                    >
                                      Confirmar
                                    </Button>
                                  </div>
                                </div>
                              )}
                              {ledger?.estado === "cargando" && (
                                <p className="boton-con-icono">
                                  <Loader2 size={16} className="icono-girando" aria-hidden="true" />
                                  Cargando movimientos…
                                </p>
                              )}
                              {ledger?.estado === "error" && (
                                <p role="alert">No se pudo cargar el historial de movimientos.</p>
                              )}
                              {ledger?.estado === "listo" && ledger.movimientos.length === 0 && (
                                <p>Sin movimientos registrados.</p>
                              )}
                              {ledger?.estado === "listo" && ledger.movimientos.length > 0 && (
                                <div className="tabla-desplazable">
                                  <table>
                                    <thead>
                                      <tr>
                                        <th>Fecha</th>
                                        <th>Tipo</th>
                                        <th>Monto</th>
                                        <th>Saldo corrido</th>
                                        <th>Motivo</th>
                                        <th>Autor</th>
                                        <th>Estado</th>
                                      </tr>
                                    </thead>
                                    <tbody>
                                      {ledger.movimientos.map((movimiento) => (
                                        <tr key={movimiento.id}>
                                          <td>{formatearFechaHora(movimiento.creado_en)}</td>
                                          <td>{ETIQUETA_TIPO_MOVIMIENTO[movimiento.tipo]}</td>
                                          <td>{formatearHorasConSigno(movimiento.monto)}</td>
                                          <td>{formatearHoras(movimiento.saldo_corrido)}</td>
                                          <td>{movimiento.motivo ?? "—"}</td>
                                          <td>{movimiento.autor_nombre ?? "Sistema"}</td>
                                          <td>
                                            <Badge variante={movimiento.vivo ? "aviso" : "neutra"}>
                                              {movimiento.vivo ? "Vigente" : "Consumido"}
                                            </Badge>
                                          </td>
                                        </tr>
                                      ))}
                                    </tbody>
                                  </table>
                                </div>
                              )}
                            </td>
                          </tr>
                        )}
                      </Fragment>
                    );
                  })}
                </tbody>
              </table>
            </div>
            <p className="pie-tabla">
              Mostrando {datos.saldos.length} de {datos.total} personas
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
