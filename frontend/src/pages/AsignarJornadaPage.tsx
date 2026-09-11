import { Fragment, type FormEvent, useEffect, useMemo, useState } from "react";
import { ArrowRight, CalendarClock, CheckCircle2, ChevronDown, ChevronRight, Clock, Search, Trash2 } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { hoyISO, sumarDiasISO } from "../lib/calendario";
import {
  DetalleJornadaAsignada,
  type EstadoJornadaVigente,
} from "../components/DetalleJornadaAsignada";
import { Badge } from "../components/Badge";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { Input } from "../components/Input";

type Persona = {
  id: string;
  primer_nombre: string;
  apellido_paterno: string;
  estado: string;
  tiene_jornada_vigente: boolean;
};

function normalizar(texto: string): string {
  return texto
    .normalize("NFD")
    .replace(new RegExp("[\\u0300-\\u036f]", "g"), "")
    .toLowerCase();
}

function formatearFecha(fecha?: string | null): string {
  if (!fecha) return "—";
  const valor = new Date(`${fecha}T00:00:00`);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" });
}

type TipoJornada = "normal" | "flexible" | "de_confianza";

const ETIQUETA_TIPO_JORNADA: Record<TipoJornada, string> = {
  normal: "Normal",
  flexible: "Flexible",
  de_confianza: "De confianza",
};

type DiaSemana =
  | "lunes"
  | "martes"
  | "miercoles"
  | "jueves"
  | "viernes"
  | "sabado"
  | "domingo";

const DIAS: { valor: DiaSemana; etiqueta: string }[] = [
  { valor: "lunes", etiqueta: "Lunes" },
  { valor: "martes", etiqueta: "Martes" },
  { valor: "miercoles", etiqueta: "Miércoles" },
  { valor: "jueves", etiqueta: "Jueves" },
  { valor: "viernes", etiqueta: "Viernes" },
  { valor: "sabado", etiqueta: "Sábado" },
  { valor: "domingo", etiqueta: "Domingo" },
];

type PatronSemanalItem = {
  dia_semana: DiaSemana;
  hora_entrada: string;
  hora_salida: string;
  minutos_comida: number;
};

type PayloadJornada = {
  persona_id: string;
  tipo_jornada: TipoJornada;
  vigente_desde: string;
  patron_semanal: PatronSemanalItem[];
  confirma_cierre_vigente?: boolean;
};

type PayloadEdicionJornada = {
  tipo_jornada: TipoJornada;
  vigente_desde: string;
  patron_semanal: PatronSemanalItem[];
};

// Fila de GET /api/personas/{id}/jornadas -- la cadena completa (pasadas + la vigente hoy +
// futuras planeadas) de esa persona. Los flags de acciones vienen calculados del backend, no se
// recalculan acá (mismo criterio que genera_alerta_horario).
type JornadaEnCadena = {
  id: number;
  tipo_jornada: TipoJornada;
  vigente_desde: string;
  vigente_hasta: string | null;
  horas_semanales_calculadas: number | null;
  patron_semanal: PatronSemanalItem[];
  estado_vigencia: "pasada" | "en_curso" | "futura";
  es_ultima_de_cadena: boolean;
  puede_editarse: boolean;
  puede_eliminarse: boolean;
  puede_mover_limite: boolean;
};

type ValoresFormulario = {
  tipoJornada: TipoJornada;
  vigenteDesde: string;
  patronPorDia: Partial<Record<DiaSemana, { hora_entrada: string; hora_salida: string; minutos_comida: number }>>;
};

type ModoEdicion = { jornadaId: number; personaId: string; tienePredecesora: boolean };

type EstadoCatalogo = "cargando" | "listo" | "error";

async function mensajeDeError(respuesta: Response, generico: string): Promise<string> {
  try {
    const cuerpo = await respuesta.json();
    if (typeof cuerpo?.detail === "string") return cuerpo.detail;
  } catch {
    // cuerpo no era JSON legible — cae al genérico
  }
  return generico;
}

export function AsignarJornadaPage() {
  const [personas, setPersonas] = useState<Persona[]>([]);
  const [estadoPersonas, setEstadoPersonas] = useState<EstadoCatalogo>("cargando");
  const [personaId, setPersonaId] = useState(
    () => new URLSearchParams(window.location.search).get("persona_id") ?? "",
  );
  const [diasSeleccionados, setDiasSeleccionados] = useState<Set<DiaSemana>>(new Set());
  const [vigenteDesdeCampo, setVigenteDesdeCampo] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);
  const [payloadPendiente, setPayloadPendiente] = useState<PayloadJornada | null>(null);
  // El usuario pidió quedarse en esta pestaña tras guardar (antes redirigía a la ficha de la
  // persona) — para poder asignar jornada a varias personas seguidas sin salir. `formKey`
  // fuerza el remount del <form> para limpiar los inputs no controlados (horarios/radios del
  // patrón semanal), que un simple setState no resetea.
  const [exito, setExito] = useState<{ mensaje: string } | null>(null);
  const [formKey, setFormKey] = useState(0);
  const [busquedaCobertura, setBusquedaCobertura] = useState("");
  // El formulario arranca cerrado (SCJ-PRA-01, mockup B elegido) — un clic en "Asignar"/"Renovar"
  // de una fila, o en la cabecera, lo abre. Mismo patrón crudo de AppShell.tsx (aria-expanded +
  // Chevron), sin componente Accordion dedicado.
  const [formAbierto, setFormAbierto] = useState(false);
  // Editar una jornada futura terminal reusa este mismo form: sembramos sus valores (radios/
  // fecha/patrón) y ramificamos el submit a PATCH. `valoresIniciales` alimenta los defaultValue/
  // defaultChecked de los campos no controlados -- junto con formKey, así se repueblan al abrir.
  const [modoEdicion, setModoEdicion] = useState<ModoEdicion | null>(null);
  const [valoresIniciales, setValoresIniciales] = useState<ValoresFormulario | null>(null);
  // Fila expandida de la tabla de cobertura: sólo una a la vez (menos estado que un Set, sin
  // pedido explícito de varias simultáneas). cadenaCache evita refetchear si se colapsa y se
  // vuelve a abrir la misma persona.
  const [filaExpandidaId, setFilaExpandidaId] = useState<string | null>(null);
  const [cadenaCache, setCadenaCache] = useState<
    Record<string, { estado: EstadoJornadaVigente; cadena: JornadaEnCadena[] }>
  >({});

  // Confirmación inline de borrado de una jornada futura terminal -- mismo patrón exacto que
  // DiasFestivosPage (sin modal, sin window.confirm: nada en el repo usa diálogos nativos).
  const [pendienteEliminarId, setPendienteEliminarId] = useState<number | null>(null);
  const [errorEliminar, setErrorEliminar] = useState<string | null>(null);
  const [eliminando, setEliminando] = useState(false);

  // Mover la fecha de término de la jornada en curso -- edición in-row estilo
  // ParametrosSistemaPage, separada del form principal.
  const [editandoLimiteId, setEditandoLimiteId] = useState<number | null>(null);
  const [nuevoLimite, setNuevoLimite] = useState("");
  const [errorLimite, setErrorLimite] = useState<string | null>(null);
  const [guardandoLimite, setGuardandoLimite] = useState(false);

  function cargarPersonas() {
    apiFetch("/api/personas")
      .then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      })
      .then((datos: Persona[]) => {
        setPersonas(datos.filter((p) => p.estado === "activo"));
        setEstadoPersonas("listo");
      })
      .catch(() => setEstadoPersonas("error"));
  }

  useEffect(cargarPersonas, []);

  function alternarDia(dia: DiaSemana) {
    setDiasSeleccionados((anterior) => {
      const siguiente = new Set(anterior);
      if (siguiente.has(dia)) {
        siguiente.delete(dia);
      } else {
        siguiente.add(dia);
      }
      return siguiente;
    });
  }

  function limpiarFormulario() {
    setPersonaId("");
    setDiasSeleccionados(new Set());
    setVigenteDesdeCampo("");
    setPayloadPendiente(null);
    setModoEdicion(null);
    setValoresIniciales(null);
    setFormKey((anterior) => anterior + 1);
    setFormAbierto(false);
  }

  async function enviarJornada(payload: PayloadJornada) {
    setEnviando(true);
    try {
      const respuesta = await apiFetch("/api/jornadas-asignadas", {
        method: "POST",
        body: JSON.stringify(payload),
      });
      if (respuesta.ok) {
        // Se queda en la pestaña de asignación de jornadas (pedido del usuario) en vez de
        // redirigir a la ficha de la persona, pero el formulario se cierra -- para asignar la
        // siguiente hay que volver a abrirlo desde el "Asignar"/"Renovar" de una fila.
        const persona = personas.find((p) => p.id === payload.persona_id);
        setExito({
          mensaje: `Jornada asignada a ${persona ? `${persona.primer_nombre} ${persona.apellido_paterno}` : "la persona"}. Podés asignar otra desde acá mismo.`,
        });
        limpiarFormulario();
        cargarPersonas(); // refresca la cobertura de abajo: esta persona ya cuenta como "con jornada"
        return;
      }
      if (respuesta.status === 409 && !payload.confirma_cierre_vigente) {
        // B1 del proceso (SCJ-PRO-09 §III): ya hay una jornada vigente — no se cierra en
        // silencio, se pide confirmación explícita antes de reintentar con la bandera.
        setPayloadPendiente(payload);
        return;
      }
      setError(await mensajeDeError(respuesta, "No se pudo registrar la asignación de jornada."));
      setPayloadPendiente(null);
    } catch {
      // Falla de red u otro error no-HTTP antes de que apiFetch resuelva una Response — sin
      // este catch, setEnviando(false) nunca corría y el botón quedaba en "Registrando…" para
      // siempre (bug real encontrado por testing probando en navegador).
      setError("No se pudo registrar la asignación de jornada. Revisa tu conexión e intenta de nuevo.");
      setPayloadPendiente(null);
    } finally {
      setEnviando(false);
    }
  }

  async function guardarEdicionJornada(personaIdEditado: string, jornadaId: number, payload: PayloadEdicionJornada) {
    setEnviando(true);
    try {
      const respuesta = await apiFetch(`/api/jornadas-asignadas/${jornadaId}`, {
        method: "PATCH",
        body: JSON.stringify(payload),
      });
      if (respuesta.ok) {
        const persona = personas.find((p) => p.id === personaIdEditado);
        setExito({
          mensaje: `Jornada de ${persona ? `${persona.primer_nombre} ${persona.apellido_paterno}` : "la persona"} actualizada.`,
        });
        limpiarFormulario();
        cargarCadenaDePersona(personaIdEditado);
        cargarPersonas();
        return;
      }
      setError(await mensajeDeError(respuesta, "No se pudo guardar la edición de la jornada."));
    } catch {
      setError("No se pudo guardar la edición de la jornada. Revisa tu conexión e intenta de nuevo.");
    } finally {
      setEnviando(false);
    }
  }

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    setExito(null);
    setPayloadPendiente(null);
    const f = new FormData(evento.currentTarget);

    const dias = DIAS.filter((d) => diasSeleccionados.has(d.valor));
    if (dias.length === 0) {
      setError("Selecciona al menos un día del patrón semanal.");
      return;
    }

    const patronSemanal: PatronSemanalItem[] = dias.map(({ valor }) => ({
      dia_semana: valor,
      hora_entrada: String(f.get(`entrada_${valor}`) ?? ""),
      hora_salida: String(f.get(`salida_${valor}`) ?? ""),
      minutos_comida: Number(f.get(`comida_${valor}`) ?? 0),
    }));

    if (modoEdicion) {
      await guardarEdicionJornada(modoEdicion.personaId, modoEdicion.jornadaId, {
        tipo_jornada: f.get("tipo_jornada") as TipoJornada,
        vigente_desde: String(f.get("vigente_desde")),
        patron_semanal: patronSemanal,
      });
      return;
    }

    await enviarJornada({
      persona_id: String(f.get("persona_id")),
      tipo_jornada: f.get("tipo_jornada") as TipoJornada,
      vigente_desde: String(f.get("vigente_desde")),
      patron_semanal: patronSemanal,
    });
  }

  function handleConfirmarCierre() {
    if (!payloadPendiente) return;
    enviarJornada({ ...payloadPendiente, confirma_cierre_vigente: true });
  }

  function handleCancelarCierre() {
    setPayloadPendiente(null);
  }

  function handleCancelarEdicion() {
    limpiarFormulario();
  }

  const sinPersonas = estadoPersonas === "listo" && personas.length === 0;
  const formularioDeshabilitado = sinPersonas || estadoPersonas === "error";

  const coberturaMetricas = useMemo(
    () => ({
      total: personas.length,
      conJornada: personas.filter((p) => p.tiene_jornada_vigente).length,
    }),
    [personas],
  );

  const coberturaFiltrada = useMemo(() => {
    const consulta = normalizar(busquedaCobertura.trim());
    return [...personas]
      .filter((p) => !consulta || normalizar(`${p.primer_nombre} ${p.apellido_paterno}`).includes(consulta))
      // Sin jornada primero — es lo accionable, lo que hay que resolver.
      .sort((a, b) => {
        if (a.tiene_jornada_vigente !== b.tiene_jornada_vigente) {
          return a.tiene_jornada_vigente ? 1 : -1;
        }
        return a.primer_nombre.localeCompare(b.primer_nombre);
      });
  }, [personas, busquedaCobertura]);

  function seleccionarParaAsignar(id: string) {
    setPersonaId(id);
    setExito(null);
    setFormAbierto(true);
  }

  async function cargarCadenaDePersona(id: string) {
    setCadenaCache((anterior) => ({ ...anterior, [id]: { estado: "cargando", cadena: [] } }));
    let resultado: { estado: EstadoJornadaVigente; cadena: JornadaEnCadena[] };
    try {
      const r = await apiFetch(`/api/personas/${id}/jornadas`);
      if (!r.ok) throw new Error(`status ${r.status}`);
      const datos: JornadaEnCadena[] = await r.json();
      resultado = { estado: datos.length === 0 ? "sin_jornada" : "listo", cadena: datos };
    } catch {
      resultado = { estado: "sin_permiso", cadena: [] };
    }
    setCadenaCache((anterior) => ({ ...anterior, [id]: resultado }));
  }

  function alternarFila(id: string) {
    if (filaExpandidaId === id) {
      setFilaExpandidaId(null);
      return;
    }
    setFilaExpandidaId(id);
    if (cadenaCache[id]) return; // ya cacheada -- no refetch al reabrir la misma persona
    cargarCadenaDePersona(id);
  }

  function iniciarEdicionJornada(personaIdEditado: string, fila: JornadaEnCadena, cadena: JornadaEnCadena[]) {
    setError(null);
    setExito(null);
    setPersonaId(personaIdEditado);
    setDiasSeleccionados(new Set(fila.patron_semanal.map((p) => p.dia_semana)));
    setVigenteDesdeCampo(fila.vigente_desde);
    const patronPorDia: ValoresFormulario["patronPorDia"] = {};
    for (const p of fila.patron_semanal) {
      patronPorDia[p.dia_semana] = {
        hora_entrada: p.hora_entrada.slice(0, 5),
        hora_salida: p.hora_salida.slice(0, 5),
        minutos_comida: p.minutos_comida,
      };
    }
    setValoresIniciales({ tipoJornada: fila.tipo_jornada, vigenteDesde: fila.vigente_desde, patronPorDia });
    const tienePredecesora = cadena.some((j) => j.vigente_desde < fila.vigente_desde);
    setModoEdicion({ jornadaId: fila.id, personaId: personaIdEditado, tienePredecesora });
    setFormKey((anterior) => anterior + 1);
    setFormAbierto(true);
  }

  function solicitarEliminarJornada(jornadaId: number) {
    setPendienteEliminarId(jornadaId);
    setErrorEliminar(null);
  }

  function cancelarEliminarJornada() {
    setPendienteEliminarId(null);
    setErrorEliminar(null);
  }

  async function confirmarEliminarJornada(personaIdAfectada: string) {
    if (pendienteEliminarId === null) return;
    setEliminando(true);
    setErrorEliminar(null);
    try {
      const respuesta = await apiFetch(`/api/jornadas-asignadas/${pendienteEliminarId}`, {
        method: "DELETE",
      });
      if (!respuesta.ok) {
        // 422 (la cadena cambió entre la carga y el click) u otro rechazo -- se muestra el
        // motivo sin cerrar la confirmación, mismo criterio que DiasFestivosPage.
        setErrorEliminar(await mensajeDeError(respuesta, "No se pudo eliminar la jornada."));
        return;
      }
      setPendienteEliminarId(null);
      cargarCadenaDePersona(personaIdAfectada);
      cargarPersonas();
    } catch {
      setErrorEliminar("No se pudo eliminar la jornada. Revisa tu conexión e intenta de nuevo.");
    } finally {
      setEliminando(false);
    }
  }

  function iniciarMoverLimite(fila: JornadaEnCadena) {
    setEditandoLimiteId(fila.id);
    setNuevoLimite("");
    setErrorLimite(null);
  }

  function cancelarMoverLimite() {
    setEditandoLimiteId(null);
    setErrorLimite(null);
  }

  async function guardarMoverLimite(personaIdAfectada: string, jornadaId: number) {
    if (!nuevoLimite) {
      setErrorLimite("Selecciona una fecha.");
      return;
    }
    setGuardandoLimite(true);
    setErrorLimite(null);
    try {
      const respuesta = await apiFetch(`/api/jornadas-asignadas/${jornadaId}/limite`, {
        method: "PATCH",
        body: JSON.stringify({ vigente_hasta: nuevoLimite }),
      });
      if (!respuesta.ok) {
        setErrorLimite(await mensajeDeError(respuesta, "No se pudo mover la fecha de término."));
        return;
      }
      setEditandoLimiteId(null);
      cargarCadenaDePersona(personaIdAfectada);
      cargarPersonas();
    } catch {
      setErrorLimite("No se pudo mover la fecha de término. Revisa tu conexión e intenta de nuevo.");
    } finally {
      setGuardandoLimite(false);
    }
  }

  return (
    <AppShell>
      {estadoPersonas === "listo" && personas.length > 0 && (
        <div className="contenedor-pagina contenedor-pagina--ancho">
          <h2>Cobertura de jornadas</h2>
          <p className="subtitulo-pagina">
            Quién de la plantilla activa ya tiene jornada vigente y a quién le falta asignarle.
          </p>

          <div className="banda-metricas">
            <div className="metrica">
              <span className="etiqueta-metrica">Personas activas</span>
              <strong>{coberturaMetricas.total}</strong>
            </div>
            <div className="metrica">
              <span className="etiqueta-metrica">
                <span className="punto punto--exito" aria-hidden="true" />
                Con jornada
              </span>
              <strong>{coberturaMetricas.conJornada}</strong>
            </div>
            <div className="metrica">
              <span className="etiqueta-metrica">
                <span className="punto punto--peligro" aria-hidden="true" />
                Sin jornada
              </span>
              <strong>{coberturaMetricas.total - coberturaMetricas.conJornada}</strong>
            </div>
          </div>

          <div className="barra-filtros">
            <div className="campo-con-icono">
              <Search size={16} className="icono-campo" aria-hidden="true" />
              <input
                type="search"
                placeholder="Buscar por nombre"
                value={busquedaCobertura}
                onChange={(evento) => setBusquedaCobertura(evento.target.value)}
                aria-label="Buscar por nombre en la cobertura de jornadas"
              />
            </div>
          </div>

          <div className="tabla-desplazable lista-desplazable">
            <table>
              <thead>
                <tr>
                  <th>Persona</th>
                  <th>Jornada</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {coberturaFiltrada.map((p) => {
                  const expandida = filaExpandidaId === p.id;
                  const cache = cadenaCache[p.id];
                  return (
                    <Fragment key={p.id}>
                      <tr className="seleccionable" onClick={() => alternarFila(p.id)}>
                        <td>
                          <span className="boton-con-icono" style={{ justifyContent: "flex-start" }}>
                            {expandida ? (
                              <ChevronDown size={16} aria-hidden="true" />
                            ) : (
                              <ChevronRight size={16} aria-hidden="true" />
                            )}
                            {p.primer_nombre} {p.apellido_paterno}
                          </span>
                        </td>
                        <td>
                          <Badge variante={p.tiene_jornada_vigente ? "exito" : "peligro"}>
                            {p.tiene_jornada_vigente ? "Con jornada" : "Sin jornada"}
                          </Badge>
                        </td>
                        <td>
                          <button
                            type="button"
                            className="boton-con-icono"
                            onClick={(evento) => {
                              evento.stopPropagation();
                              seleccionarParaAsignar(p.id);
                            }}
                          >
                            {p.tiene_jornada_vigente ? "Renovar" : "Asignar"}
                          </button>
                        </td>
                      </tr>
                      {expandida && (
                        <tr>
                          <td colSpan={3}>
                            {(!cache || cache.estado !== "listo") ? (
                              <DetalleJornadaAsignada estado={cache?.estado ?? "cargando"} jornada={null} />
                            ) : (
                              <div className="lista-jornadas-cadena">
                                {cache.cadena.map((fila) => {
                                  const tienePredecesora = cache.cadena.some(
                                    (j) => j.vigente_desde < fila.vigente_desde,
                                  );
                                  const candidatasSucesora = cache.cadena.filter(
                                    (j) => j.vigente_desde > fila.vigente_desde,
                                  );
                                  const sucesora = candidatasSucesora.reduce<JornadaEnCadena | null>(
                                    (min, j) => (!min || j.vigente_desde < min.vigente_desde ? j : min),
                                    null,
                                  );
                                  return (
                                    <div key={fila.id} className="tarjeta-jornada-cadena">
                                      <p className="meta-ficha">
                                        <Badge
                                          variante={
                                            fila.estado_vigencia === "en_curso"
                                              ? "exito"
                                              : fila.estado_vigencia === "futura"
                                                ? "aviso"
                                                : "neutra"
                                          }
                                        >
                                          {fila.estado_vigencia === "en_curso"
                                            ? "En curso"
                                            : fila.estado_vigencia === "futura"
                                              ? "Futura"
                                              : "Pasada"}
                                        </Badge>{" "}
                                        {formatearFecha(fila.vigente_desde)} –{" "}
                                        {fila.vigente_hasta ? formatearFecha(fila.vigente_hasta) : "sin fecha de término"}
                                      </p>
                                      <DetalleJornadaAsignada estado="listo" jornada={fila} />
                                      <div className="botonera">
                                        <Button
                                          type="button"
                                          disabled={!fila.puede_editarse}
                                          title={
                                            !fila.puede_editarse
                                              ? "Sólo se puede editar la última jornada planeada, y sólo si todavía no empezó."
                                              : undefined
                                          }
                                          aria-label={
                                            !fila.puede_editarse
                                              ? "No se puede editar esta jornada: sólo la última planeada, y sólo si todavía no empezó"
                                              : undefined
                                          }
                                          onClick={() => iniciarEdicionJornada(p.id, fila, cache.cadena)}
                                        >
                                          Editar
                                        </Button>
                                        <Button
                                          type="button"
                                          icono={Trash2}
                                          disabled={!fila.puede_eliminarse}
                                          title={
                                            !fila.puede_eliminarse
                                              ? "Sólo se puede eliminar la última jornada planeada, y sólo si todavía no empezó."
                                              : undefined
                                          }
                                          aria-label={
                                            !fila.puede_eliminarse
                                              ? "No se puede eliminar esta jornada: sólo la última planeada, y sólo si todavía no empezó"
                                              : undefined
                                          }
                                          onClick={() => solicitarEliminarJornada(fila.id)}
                                        >
                                          Eliminar
                                        </Button>
                                        {fila.puede_mover_limite && editandoLimiteId !== fila.id && (
                                          <Button type="button" onClick={() => iniciarMoverLimite(fila)}>
                                            Mover fecha de término
                                          </Button>
                                        )}
                                      </div>

                                      {pendienteEliminarId === fila.id && (
                                        <div className="tarjeta-info">
                                          <p role="alert">
                                            ¿Eliminar esta jornada ({formatearFecha(fila.vigente_desde)} –{" "}
                                            {fila.vigente_hasta ? formatearFecha(fila.vigente_hasta) : "sin fecha de término"})?
                                            {tienePredecesora &&
                                              " La jornada anterior volverá a quedar sin fecha de término."}
                                          </p>
                                          {errorEliminar && <p role="alert">{errorEliminar}</p>}
                                          <div className="botonera">
                                            <Button type="button" onClick={cancelarEliminarJornada}>
                                              Cancelar
                                            </Button>
                                            <Button
                                              type="button"
                                              variante="primario"
                                              cargando={eliminando}
                                              textoCargando="Eliminando…"
                                              onClick={() => confirmarEliminarJornada(p.id)}
                                            >
                                              Sí, eliminar
                                            </Button>
                                          </div>
                                        </div>
                                      )}

                                      {editandoLimiteId === fila.id && (
                                        <div className="campo">
                                          <label htmlFor={`limite-${fila.id}`}>Nueva fecha de término</label>
                                          <input
                                            id={`limite-${fila.id}`}
                                            type="date"
                                            min={sumarDiasISO(hoyISO(), 1)}
                                            value={nuevoLimite}
                                            onChange={(evento) => setNuevoLimite(evento.target.value)}
                                          />
                                          {nuevoLimite && sucesora && (
                                            <p className="ayuda-campo">
                                              El siguiente tramo ({ETIQUETA_TIPO_JORNADA[sucesora.tipo_jornada]}) pasará
                                              a comenzar el {formatearFecha(sumarDiasISO(nuevoLimite, 1))}.
                                            </p>
                                          )}
                                          {errorLimite && <p role="alert">{errorLimite}</p>}
                                          <div className="botonera">
                                            <Button type="button" onClick={cancelarMoverLimite}>
                                              Cancelar
                                            </Button>
                                            <Button
                                              type="button"
                                              variante="primario"
                                              cargando={guardandoLimite}
                                              textoCargando="Guardando…"
                                              onClick={() => guardarMoverLimite(p.id, fila.id)}
                                            >
                                              Guardar
                                            </Button>
                                          </div>
                                        </div>
                                      )}
                                    </div>
                                  );
                                })}
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
        </div>
      )}

      <div className="contenedor-pagina">
        {exito && (
          <div className="tarjeta-info">
            <CheckCircle2 size={16} aria-hidden="true" />
            <span>{exito.mensaje}</span>
          </div>
        )}

      {formAbierto && (
      <form key={formKey} onSubmit={handleSubmit}>
        <fieldset className="fieldset-formulario">
          <legend className="encabezado-fieldset">
            <span className="icono-seccion">
              <CalendarClock size={16} aria-hidden="true" />
            </span>
            Datos de la jornada
          </legend>

          <div className="campo">
            <label htmlFor="persona_id">Persona</label>
            <select
              id="persona_id"
              name="persona_id"
              required
              disabled={sinPersonas || estadoPersonas === "error" || !!modoEdicion}
              value={personaId}
              onChange={(evento) => setPersonaId(evento.target.value)}
              aria-describedby={
                sinPersonas || estadoPersonas === "error" ? "persona_id-ayuda" : undefined
              }
            >
              <option value="">Selecciona una persona activa</option>
              {personas.map((persona) => (
                <option key={persona.id} value={persona.id}>
                  {persona.primer_nombre} {persona.apellido_paterno}
                </option>
              ))}
            </select>
            {sinPersonas && (
              <small className="ayuda-campo" id="persona_id-ayuda">
                No hay personas activas para asignar.
              </small>
            )}
            {estadoPersonas === "error" && (
              <small className="ayuda-campo" id="persona_id-ayuda">
                No se pudo cargar el padrón de personas.
              </small>
            )}
          </div>

          <div className="campo">
            <span>Tipo de jornada</span>
            <div className="opciones-seleccionables opciones-seleccionables--compacta">
              <label className="opcion-seleccionable">
                <input
                  type="radio"
                  name="tipo_jornada"
                  value="normal"
                  defaultChecked={(valoresIniciales?.tipoJornada ?? "normal") === "normal"}
                  required
                />
                <span className="texto-opcion">
                  <strong>Normal</strong>
                  <span>Horario fijo, valida tope legal semanal</span>
                </span>
              </label>
              <label className="opcion-seleccionable">
                <input
                  type="radio"
                  name="tipo_jornada"
                  value="flexible"
                  defaultChecked={valoresIniciales?.tipoJornada === "flexible"}
                />
                <span className="texto-opcion">
                  <strong>Flexible</strong>
                  <span>Sin tope legal por horario fijo</span>
                </span>
              </label>
              <label className="opcion-seleccionable">
                <input
                  type="radio"
                  name="tipo_jornada"
                  value="de_confianza"
                  defaultChecked={valoresIniciales?.tipoJornada === "de_confianza"}
                />
                <span className="texto-opcion">
                  <strong>De confianza</strong>
                  <span>No registra marca ni banco de horas</span>
                </span>
              </label>
            </div>
          </div>

          <Input
            id="vigente_desde"
            name="vigente_desde"
            label="Vigente desde"
            type="date"
            required
            value={vigenteDesdeCampo}
            onChange={(evento) => setVigenteDesdeCampo(evento.target.value)}
            ayuda={
              modoEdicion?.tienePredecesora && vigenteDesdeCampo
                ? `La jornada anterior pasará a terminar el ${formatearFecha(sumarDiasISO(vigenteDesdeCampo, -1))}.`
                : "Si la persona ya tiene una jornada vigente, se pedirá confirmar el cierre de esa jornada un día antes de esta fecha."
            }
          />
        </fieldset>

        <fieldset className="fieldset-formulario">
          <legend className="encabezado-fieldset">
            <span className="icono-seccion">
              <Clock size={16} aria-hidden="true" />
            </span>
            Patrón semanal
          </legend>
          <p className="ayuda-campo">Marca los días que trabaja y captura su horario.</p>

          <div className="opciones-seleccionables">
            {DIAS.map(({ valor, etiqueta }) => {
              const marcado = diasSeleccionados.has(valor);
              const valoresDia = valoresIniciales?.patronPorDia[valor];
              return (
                <div key={valor}>
                  <label className="opcion-seleccionable">
                    <input
                      type="checkbox"
                      checked={marcado}
                      onChange={() => alternarDia(valor)}
                    />
                    <span className="texto-opcion">
                      <strong>{etiqueta}</strong>
                    </span>
                  </label>
                  {marcado && (
                    <div className="rejilla-campos">
                      <Input
                        id={`entrada_${valor}`}
                        name={`entrada_${valor}`}
                        label="Hora de entrada"
                        type="time"
                        defaultValue={valoresDia?.hora_entrada}
                        required
                      />
                      <Input
                        id={`salida_${valor}`}
                        name={`salida_${valor}`}
                        label="Hora de salida"
                        type="time"
                        defaultValue={valoresDia?.hora_salida}
                        required
                      />
                      <Input
                        id={`comida_${valor}`}
                        name={`comida_${valor}`}
                        label="Minutos de comida"
                        type="number"
                        min={0}
                        defaultValue={valoresDia?.minutos_comida ?? 0}
                        required
                      />
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </fieldset>

        {payloadPendiente && (
          <Card>
            <p role="alert">
              Esta persona ya tiene una jornada vigente. ¿Cerrarla y dejar vigente la nueva a partir
              del día anterior a {payloadPendiente.vigente_desde}?
            </p>
            <div className="botonera">
              <Button type="button" onClick={handleCancelarCierre}>
                Cancelar
              </Button>
              <Button
                type="button"
                variante="primario"
                cargando={enviando}
                textoCargando="Cerrando y asignando…"
                onClick={handleConfirmarCierre}
              >
                Sí, cerrar la anterior y asignar
              </Button>
            </div>
          </Card>
        )}

        {error && <p role="alert">{error}</p>}
        <div className="botonera">
          {modoEdicion ? (
            <Button type="button" onClick={handleCancelarEdicion}>
              Cancelar
            </Button>
          ) : (
            <a href="/personas">Cancelar</a>
          )}
          <Button
            type="submit"
            icono={modoEdicion ? undefined : ArrowRight}
            disabled={formularioDeshabilitado || !!payloadPendiente}
            cargando={enviando && !payloadPendiente}
            textoCargando={modoEdicion ? "Guardando…" : "Registrando…"}
          >
            {modoEdicion ? "Guardar cambios" : "Registrar"}
          </Button>
        </div>
      </form>
      )}
      </div>
    </AppShell>
  );
}
