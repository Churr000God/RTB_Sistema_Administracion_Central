import { useCallback, useEffect, useMemo, useState } from "react";
import { useParams } from "react-router-dom";
import { AlertCircle, AlertTriangle, CheckCircle2, History, Loader2, Lock, Search, Trash2, UserPlus, X } from "lucide-react";

import { AppShell } from "../layouts/AppShell";
import { AsignarPersonaTerminalModal } from "../components/AsignarPersonaTerminalModal";
import { Badge } from "../components/Badge";
import { BajaAltaModal } from "../components/BajaAltaModal";
import { Button } from "../components/Button";
import { CuentaRegresivaAlta } from "../components/CuentaRegresivaAlta";
import { EstadoAltaBadge } from "../components/EstadoAltaBadge";
import { HistorialAltaModal } from "../components/HistorialAltaModal";
import { ReconsentimientoModal } from "../components/ReconsentimientoModal";
import { Input } from "../components/Input";
import { SinAccesoTerminales } from "../components/SinAccesoTerminales";
import { formatearHoraMexico } from "../lib/calendario";
import { ErrorApi, apiJson } from "../lib/errorApi";
import { useSesion } from "../lib/useSesion";
import {
  ETIQUETA_CONTACTO,
  ETIQUETA_ESTADO_ALTA,
  ETIQUETA_RAZON_NO_ELEGIBLE,
  MAX_LOTE_RECONSENTIMIENTO,
  type Alta,
  type EstadoAlta,
  type EstadoContacto,
  type RespuestaAltas,
  type Terminal,
} from "../lib/terminales";

const LIMITE_SERVIDOR = 200;
type FiltroReconsentimiento = "" | "pendiente" | "al_corriente";
const TAMANO_PAGINA = 20;

type Estado = "cargando" | "listo" | "error" | "sin_acceso" | "no_existe";

type ModalAbierto =
  | { tipo: "asignar" }
  | { tipo: "baja"; alta: Alta; accion: "cancelar_alta" | "dar_de_baja" }
  | { tipo: "historial"; alta: Alta }
  | { tipo: "reconsentimiento"; ids: number[] };

const AYUDA_ESTADO: Partial<Record<EstadoAlta, string>> = {
  pendiente_alta: "El puente aún no la crea en el aparato",
  esperando_huella: "Esperando que TI enrole la huella en la terminal",
  pendiente_baja: "El puente borrará el usuario y sus huellas del aparato",
  baja: "Dato biométrico dado de baja",
};

const PUNTO_CONTACTO: Record<EstadoContacto, string> = {
  en_linea: "punto punto--exito",
  sin_contacto: "punto punto--aviso",
  nunca: "punto",
  inactiva: "punto",
};

function normalizar(texto: string): string {
  return texto
    .normalize("NFD")
    .replace(new RegExp("[\\u0300-\\u036f]", "g"), "")
    .toLowerCase();
}

function formatearFecha(fecha: string): string {
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "—";
  return formatearHoraMexico(valor, {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function UsuariosTerminalPage() {
  const { id } = useParams<{ id: string }>();
  const { sesion, cargando: cargandoSesion } = useSesion();
  const sinAccesoPorSesion = sesion?.puede_ver_terminales === false;
  const puedeEditar = sesion?.puede_editar_terminales === true;
  const sesionCargada = sesion !== null;

  const [terminal, setTerminal] = useState<Terminal | null>(null);
  const [respuesta, setRespuesta] = useState<RespuestaAltas | null>(null);
  const [estado, setEstado] = useState<Estado>("cargando");
  const [filtroEstado, setFiltroEstado] = useState<EstadoAlta | "">("");
  const [desde, setDesde] = useState("");
  const [busqueda, setBusqueda] = useState("");
  const [pagina, setPagina] = useState(0);
  const [modal, setModal] = useState<ModalAbierto | null>(null);
  const [filtroReconsentimiento, setFiltroReconsentimiento] = useState<FiltroReconsentimiento>("");
  const [seleccion, setSeleccion] = useState<Set<number>>(new Set());
  const [avisoSeleccion, setAvisoSeleccion] = useState<string | null>(null);

  const cargar = useCallback(() => {
    if (!id) return;
    setEstado("cargando");
    const params = new URLSearchParams();
    if (filtroEstado) params.set("estado", filtroEstado);
    if (desde) params.set("desde", desde);
    if (filtroReconsentimiento) params.set("reconsentimiento", filtroReconsentimiento);
    params.set("limite", String(LIMITE_SERVIDOR));

    Promise.all([
      apiJson<Terminal>(`/api/terminales/${id}`),
      apiJson<RespuestaAltas>(`/api/terminales/${id}/usuarios?${params.toString()}`),
    ])
      .then(([datosTerminal, datosAltas]) => {
        if (!Array.isArray(datosAltas?.altas) || !datosAltas.resumen) throw new Error("forma inesperada");
        setTerminal(datosTerminal);
        setRespuesta(datosAltas);
        setEstado("listo");
      })
      .catch((error) => {
        if (error instanceof ErrorApi && error.status === 403) setEstado("sin_acceso");
        else if (error instanceof ErrorApi && error.status === 404) setEstado("no_existe");
        else setEstado("error");
      });
  }, [id, filtroEstado, desde, filtroReconsentimiento]);

  useEffect(() => {
    if (cargandoSesion || sinAccesoPorSesion) return;
    cargar();
  }, [cargandoSesion, sinAccesoPorSesion, cargar]);

  useEffect(() => {
    setPagina(0);
  }, [busqueda, filtroEstado, desde, filtroReconsentimiento]);

  const filtradas = useMemo(() => {
    const consulta = normalizar(busqueda.trim());
    const altas = respuesta?.altas ?? [];
    if (!consulta) return altas;
    return altas.filter((alta) => normalizar(alta.persona_nombre ?? "").includes(consulta));
  }, [respuesta, busqueda]);

  const totalPaginas = Math.max(1, Math.ceil(filtradas.length / TAMANO_PAGINA));
  const visibles = filtradas.slice(pagina * TAMANO_PAGINA, (pagina + 1) * TAMANO_PAGINA);
  const sinAcceso = sinAccesoPorSesion || estado === "sin_acceso";
  const hayFiltros = !!(filtroEstado || desde || busqueda || filtroReconsentimiento);
  const pendientesReconsentimiento = respuesta?.resumen.reconsentimiento_pendiente ?? 0;

  function cerrarModal(refrescar: boolean) {
    setModal(null);
    if (refrescar) {
      setSeleccion(new Set());
      setAvisoSeleccion(null);
      cargar();
    }
  }

  function alternar(idAlta: number) {
    setAvisoSeleccion(null);
    setSeleccion((actual) => {
      const siguiente = new Set(actual);
      if (siguiente.has(idAlta)) siguiente.delete(idAlta);
      else siguiente.add(idAlta);
      return siguiente;
    });
  }

  async function seleccionarTodasElegibles() {
    setAvisoSeleccion(null);
    try {
      const r = await apiJson<{ total: number; ids: number[]; hay_mas?: boolean }>(
        `/api/terminales/${id}/reconsentimientos-pendientes`,
      );
      if (!Array.isArray(r.ids)) throw new Error("forma inesperada");
      setSeleccion(new Set(r.ids));
      if (r.total > r.ids.length) {
        setAvisoSeleccion(`Máximo ${MAX_LOTE_RECONSENTIMIENTO} por vez; quedan ${r.total - r.ids.length} pendientes para después.`);
      }
    } catch {
      setAvisoSeleccion("No se pudo obtener la lista de pendientes. Selecciona las filas a mano.");
    }
  }



  function detalleError(alta: Alta): string | null {
    if (!alta.error_detalle && !alta.error_codigo) return null;
    const partes = [alta.error_codigo, alta.error_detalle].filter(Boolean).join(" — ");
    return `Último error del puente: ${partes}`;
  }

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <a href="/tiempo/terminales">Terminales</a> / <strong>{terminal?.nombre ?? "Usuarios"}</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Usuarios de la terminal</h1>
            {terminal && (
              <p className="subtitulo-pagina">
                {terminal.nombre} · {terminal.serie} ·{" "}
                <span className="contacto">
                  <span className={PUNTO_CONTACTO[terminal.estado_contacto]} aria-hidden="true" />
                  {ETIQUETA_CONTACTO[terminal.estado_contacto]}
                </span>
                . La huella se enrola en el menú del aparato (TI con RH presente); aquí sólo se asigna, se da
                seguimiento y se da de baja.
              </p>
            )}
          </div>
          {puedeEditar && terminal?.activa && estado === "listo" && (
            <Button variante="primario" icono={UserPlus} posicionIcono="izquierda" onClick={() => setModal({ tipo: "asignar" })}>
              Asignar persona
            </Button>
          )}
        </div>

        {sinAcceso && <SinAccesoTerminales />}

        {!sinAcceso && sesionCargada && !puedeEditar && estado !== "no_existe" && (
          <div className="banner-aviso banner-aviso--info" role="note">
            <Lock size={16} aria-hidden="true" />
            <div>
              <strong>Puedes consultar estas altas, no modificarlas.</strong> Asignar o dar de baja a una persona
              requiere el permiso <span className="chip-permiso">terminal_usuario_edicion</span>. Pídelo a
              Recursos Humanos o a TI.
            </div>
          </div>
        )}

        {!sinAcceso && estado === "no_existe" && (
          <div className="estado-vacio">
            <p>
              <strong>La terminal no existe.</strong>
              <br />
              <a href="/tiempo/terminales">Volver a Terminales</a>
            </p>
          </div>
        )}

        {!sinAcceso && estado === "cargando" && (
          <p className="boton-con-icono" role="status">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando usuarios de la terminal…
          </p>
        )}

        {!sinAcceso && estado === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar los usuarios de la terminal
            </strong>
            <p>Ocurrió un problema al consultar las altas.</p>
            <Button onClick={cargar}>Reintentar</Button>
          </div>
        )}

        {!sinAcceso && estado === "listo" && respuesta && (
          <>
            <div className="banda-metricas">
              <div className="metrica">
                <span className="etiqueta-metrica">
                  <span className="punto punto--exito" aria-hidden="true" />
                  Activos
                </span>
                <strong>{respuesta.resumen.por_estado.activo ?? 0}</strong>
              </div>
              <div className="metrica">
                <span className="etiqueta-metrica">
                  <span className="punto punto--aviso" aria-hidden="true" />
                  Esperando huella
                </span>
                <strong>{respuesta.resumen.por_estado.esperando_huella ?? 0}</strong>
              </div>
              <div className="metrica">
                <span className="etiqueta-metrica">Pendientes de alta / baja</span>
                <strong>
                  {respuesta.resumen.por_estado.pendiente_alta ?? 0} /{" "}
                  {respuesta.resumen.por_estado.pendiente_baja ?? 0}
                </strong>
              </div>
              {pendientesReconsentimiento > 0 && (
                <div className="metrica">
                  <span className="etiqueta-metrica">
                    <span className="punto punto--peligro" aria-hidden="true" />
                    Reconsentimiento pendiente
                  </span>
                  <strong>{pendientesReconsentimiento}</strong>
                </div>
              )}
            </div>

            {pendientesReconsentimiento > 0 && (
              <div className="banner-aviso" role="note">
                <AlertTriangle size={16} aria-hidden="true" />
                <div>
                  <strong>{pendientesReconsentimiento} personas deben reconsentir.</strong> El texto de consentimiento
                  cambió de forma material. <strong>No se bloquea ninguna marca</strong>: sólo se señala. Cuentan las
                  altas en «Pendiente de alta», «Esperando huella» y «Activo»; las de «Pendiente de baja» y «Baja» no.
                  Ni su estado ni su huella cambian.
                </div>
              </div>
            )}

            <div className="barra-filtros">
              <div className="campo-con-icono">
                <Search size={16} className="icono-campo" aria-hidden="true" />
                <input
                  type="search"
                  placeholder="Buscar por persona"
                  aria-label="Buscar por persona"
                  value={busqueda}
                  onChange={(evento) => setBusqueda(evento.target.value)}
                />
              </div>
              <div className="grupo-filtros-secundarios">
                <select
                  aria-label="Filtrar por estado"
                  value={filtroEstado}
                  onChange={(evento) => setFiltroEstado(evento.target.value as EstadoAlta | "")}
                >
                  <option value="">Estado: Todos</option>
                  {(Object.keys(ETIQUETA_ESTADO_ALTA) as EstadoAlta[]).map((clave) => (
                    <option key={clave} value={clave}>
                      {ETIQUETA_ESTADO_ALTA[clave]}
                    </option>
                  ))}
                </select>
                <select
                  aria-label="Filtrar por reconsentimiento"
                  value={filtroReconsentimiento}
                  onChange={(evento) => setFiltroReconsentimiento(evento.target.value as FiltroReconsentimiento)}
                >
                  <option value="">Reconsentimiento: Todos</option>
                  <option value="pendiente">Pendiente</option>
                  <option value="al_corriente">Al corriente</option>
                </select>
                <Input
                  id="filtro-asignada-desde"
                  label="Asignada desde"
                  type="date"
                  value={desde}
                  onChange={(evento) => setDesde(evento.target.value)}
                />
              </div>
            </div>

            {respuesta.total > LIMITE_SERVIDOR && (
              <div className="banner-aviso banner-aviso--info" role="note">
                <AlertTriangle size={16} aria-hidden="true" />
                <div>
                  Mostrando las {LIMITE_SERVIDOR} más recientes de {respuesta.total}. Afina los filtros para ver el
                  resto.
                </div>
              </div>
            )}

            {respuesta.altas.length === 0 && !hayFiltros && (
              <div className="estado-vacio">
                <UserPlus size={40} aria-hidden="true" />
                <p>
                  <strong>Esta terminal todavía no tiene personas asignadas.</strong>
                  <br />
                  Quien marca por captura manual no necesita asignación.
                </p>
              </div>
            )}

            {filtradas.length === 0 && (respuesta.altas.length > 0 || hayFiltros) && (
              <div className="estado-vacio">
                <p>Ninguna alta coincide con la búsqueda.</p>
              </div>
            )}

            {puedeEditar && pendientesReconsentimiento > 0 && (
              <div className="barra-filtros" role="region" aria-label="Acciones en lote" style={{ alignItems: "center" }}>
                <Button onClick={seleccionarTodasElegibles}>Seleccionar todas las elegibles</Button>
                <span className="rango">(máximo {MAX_LOTE_RECONSENTIMIENTO} por vez; tu propia alta no es elegible)</span>
                {seleccion.size > 0 && (
                  <>
                    <strong className="num">
                      {seleccion.size} {seleccion.size === 1 ? "seleccionada" : "seleccionadas"}
                    </strong>
                    <Button onClick={() => setSeleccion(new Set())}>Limpiar</Button>
                    <Button
                      variante="primario"
                      icono={CheckCircle2}
                      posicionIcono="izquierda"
                      onClick={() => setModal({ tipo: "reconsentimiento", ids: [...seleccion] })}
                    >
                      Registrar reconsentimiento de las seleccionadas…
                    </Button>
                  </>
                )}
                {avisoSeleccion && <span className="rango">{avisoSeleccion}</span>}
              </div>
            )}

            {filtradas.length > 0 && (
              <>
                <div className="tabla-desplazable">
                  <table>
                    <thead>
                      <tr>
                        {puedeEditar && pendientesReconsentimiento > 0 && <th aria-label="Selección"></th>}
                        <th>Persona</th>
                        <th>Nº en la terminal</th>
                        <th>Estado</th>
                        <th>Huellas</th>
                        <th>Asignada</th>
                        <th>Detalle</th>
                        <th>Acciones</th>
                      </tr>
                    </thead>
                    <tbody>
                      {visibles.map((alta) => {
                        const error = detalleError(alta);
                        const ayuda = AYUDA_ESTADO[alta.estado];
                        return (
                          <tr key={alta.id}>
                            {puedeEditar && pendientesReconsentimiento > 0 && (
                              <td>
                                {alta.reconsentimiento_pendiente && (
                                  <input
                                    type="checkbox"
                                    style={{ width: "auto" }}
                                    aria-label={`Seleccionar a ${alta.persona_nombre ?? "la persona"}`}
                                    checked={seleccion.has(alta.id)}
                                    disabled={!alta.reconsentimiento_elegible}
                                    onChange={() => alternar(alta.id)}
                                  />
                                )}
                              </td>
                            )}
                            <td>{alta.persona_nombre ?? "—"}</td>
                            <td className="num">{alta.employee_no}</td>
                            <td>
                              <EstadoAltaBadge estado={alta.estado} />
                              {ayuda && <div className="ayuda-campo">{ayuda}</div>}
                              {alta.estado === "esperando_huella" && alta.caduca_en && (
                                <CuentaRegresivaAlta caducaEn={alta.caduca_en} />
                              )}
                              {alta.reconsentimiento_pendiente && (
                                <div style={{ marginTop: "0.3rem" }}>
                                  <Badge variante="peligro" className="estado-alta">
                                    <AlertTriangle size={12} aria-hidden="true" />
                                    Reconsentimiento pendiente
                                  </Badge>
                                  <div className="ayuda-campo">
                                    Confirmó el texto v{alta.consentimiento?.version ?? "?"}; hay una versión más nueva
                                    (cambio material)
                                  </div>
                                  {puedeEditar && !alta.reconsentimiento_elegible && alta.reconsentimiento_razon && (
                                    <div className="sin-accion">
                                      <Lock size={14} aria-hidden="true" />
                                      {ETIQUETA_RAZON_NO_ELEGIBLE[alta.reconsentimiento_razon] ?? "No es elegible ahora."}
                                    </div>
                                  )}
                                </div>
                              )}
                            </td>
                            <td className="num">
                              {alta.estado === "pendiente_alta" || alta.estado === "baja"
                                ? "—"
                                : alta.huellas_capturadas}
                            </td>
                            <td className="num">{formatearFecha(alta.creado_en)}</td>
                            <td>
                              {error ? (
                                <div className="error-terminal">
                                  <AlertCircle size={14} aria-hidden="true" />
                                  {error}
                                </div>
                              ) : (
                                "—"
                              )}
                            </td>
                            <td>
                              {puedeEditar && alta.accion_disponible === "cancelar_alta" && (
                                <Button icono={X} posicionIcono="izquierda" tamanoIcono={14} onClick={() => setModal({ tipo: "baja", alta, accion: "cancelar_alta" })}>
                                  Cancelar alta
                                </Button>
                              )}
                              {puedeEditar && alta.accion_disponible === "dar_de_baja" && (
                                <Button icono={Trash2} posicionIcono="izquierda" tamanoIcono={14} onClick={() => setModal({ tipo: "baja", alta, accion: "dar_de_baja" })}>
                                  Dar de baja
                                </Button>
                              )}{" "}
                              {puedeEditar && alta.reconsentimiento_pendiente && alta.reconsentimiento_elegible && (
                                <Button
                                  icono={CheckCircle2}
                                  posicionIcono="izquierda"
                                  tamanoIcono={14}
                                  onClick={() => setModal({ tipo: "reconsentimiento", ids: [alta.id] })}
                                >
                                  Registrar reconsentimiento
                                </Button>
                              )}{" "}
                              <Button icono={History} posicionIcono="izquierda" tamanoIcono={14} onClick={() => setModal({ tipo: "historial", alta })}>
                                Historial
                              </Button>
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
                <p className="pie-tabla">
                  Mostrando {pagina * TAMANO_PAGINA + 1}–{pagina * TAMANO_PAGINA + visibles.length} de{" "}
                  {filtradas.length}
                </p>
                {totalPaginas > 1 && (
                  <div className="botonera">
                    <Button disabled={pagina === 0} onClick={() => setPagina((p) => p - 1)}>
                      Anterior
                    </Button>
                    <Button disabled={pagina >= totalPaginas - 1} onClick={() => setPagina((p) => p + 1)}>
                      Siguiente
                    </Button>
                  </div>
                )}
              </>
            )}
          </>
        )}
        {modal?.tipo === "asignar" && terminal && (
          <AsignarPersonaTerminalModal
            terminal={{ id: terminal.id, nombre: terminal.nombre }}
            personaDelCaller={sesion?.persona_id}
            onCerrar={cerrarModal}
          />
        )}
        {modal?.tipo === "baja" && terminal && (
          <BajaAltaModal terminalId={terminal.id} alta={modal.alta} accion={modal.accion} onCerrar={cerrarModal} />
        )}
        {modal?.tipo === "reconsentimiento" && terminal && (
          <ReconsentimientoModal
            terminalId={terminal.id}
            altas={modal.ids.map((idAlta) => ({
              id: idAlta,
              persona_nombre: respuesta?.altas.find((a) => a.id === idAlta)?.persona_nombre ?? null,
            }))}
            onCerrar={cerrarModal}
          />
        )}
        {modal?.tipo === "historial" && terminal && (
          <HistorialAltaModal terminalId={terminal.id} alta={modal.alta} onCerrar={() => setModal(null)} />
        )}
      </div>
    </AppShell>
  );
}
