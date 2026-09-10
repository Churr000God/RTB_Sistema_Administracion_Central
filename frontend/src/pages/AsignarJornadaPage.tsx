import { Fragment, type FormEvent, useEffect, useMemo, useState } from "react";
import { ArrowRight, CalendarClock, CheckCircle2, ChevronDown, ChevronRight, Clock, Search } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import {
  DetalleJornadaAsignada,
  type EstadoJornadaVigente,
  type JornadaVigente,
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

type TipoJornada = "normal" | "flexible" | "de_confianza";

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
  const [error, setError] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);
  const [payloadPendiente, setPayloadPendiente] = useState<PayloadJornada | null>(null);
  // El usuario pidió quedarse en esta pestaña tras guardar (antes redirigía a la ficha de la
  // persona) — para poder asignar jornada a varias personas seguidas sin salir. `formKey`
  // fuerza el remount del <form> para limpiar los inputs no controlados (horarios/radios del
  // patrón semanal), que un simple setState no resetea.
  const [exito, setExito] = useState<{ nombrePersona: string } | null>(null);
  const [formKey, setFormKey] = useState(0);
  const [busquedaCobertura, setBusquedaCobertura] = useState("");
  // El formulario arranca cerrado (SCJ-PRA-01, mockup B elegido) — un clic en "Asignar"/"Renovar"
  // de una fila, o en la cabecera, lo abre. Mismo patrón crudo de AppShell.tsx (aria-expanded +
  // Chevron), sin componente Accordion dedicado.
  const [formAbierto, setFormAbierto] = useState(false);
  // Fila expandida de la tabla de cobertura: sólo una a la vez (menos estado que un Set, sin
  // pedido explícito de varias simultáneas). jornadaCache evita refetchear si se colapsa y se
  // vuelve a abrir la misma persona.
  const [filaExpandidaId, setFilaExpandidaId] = useState<string | null>(null);
  const [jornadaCache, setJornadaCache] = useState<
    Record<string, { estado: EstadoJornadaVigente; jornada: JornadaVigente | null }>
  >({});

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

  async function enviarJornada(payload: PayloadJornada) {
    setEnviando(true);
    try {
      const respuesta = await apiFetch("/api/jornadas-asignadas", {
        method: "POST",
        body: JSON.stringify(payload),
      });
      if (respuesta.ok) {
        // Se queda en la pestaña de asignación de jornadas (pedido del usuario) en vez de
        // redirigir a la ficha de la persona — permite asignar la siguiente sin salir de acá.
        const persona = personas.find((p) => p.id === payload.persona_id);
        setExito({ nombrePersona: persona ? `${persona.primer_nombre} ${persona.apellido_paterno}` : "la persona" });
        setPersonaId("");
        setDiasSeleccionados(new Set());
        setPayloadPendiente(null);
        setFormKey((anterior) => anterior + 1);
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

  async function cargarJornadaDePersona(id: string) {
    setJornadaCache((anterior) => ({ ...anterior, [id]: { estado: "cargando", jornada: null } }));
    let resultado: { estado: EstadoJornadaVigente; jornada: JornadaVigente | null };
    try {
      const r = await apiFetch(`/api/personas/${id}/jornada-vigente`);
      if (r.status === 404) {
        resultado = { estado: "sin_jornada", jornada: null };
      } else if (!r.ok) {
        throw new Error(`status ${r.status}`);
      } else {
        const datos: JornadaVigente = await r.json();
        resultado = { estado: "listo", jornada: datos };
      }
    } catch {
      resultado = { estado: "sin_permiso", jornada: null };
    }
    setJornadaCache((anterior) => ({ ...anterior, [id]: resultado }));
  }

  function alternarFila(id: string) {
    if (filaExpandidaId === id) {
      setFilaExpandidaId(null);
      return;
    }
    setFilaExpandidaId(id);
    if (jornadaCache[id]) return; // ya cacheada -- no refetch al reabrir la misma persona
    cargarJornadaDePersona(id);
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
                  const cache = jornadaCache[p.id];
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
                            <DetalleJornadaAsignada
                              estado={cache?.estado ?? "cargando"}
                              jornada={cache?.jornada ?? null}
                            />
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
        <nav className="migas">
          <strong>Asignación de jornada</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Asignar jornada</h1>
            <p className="subtitulo-pagina">
              Da de alta o renueva la jornada y el patrón semanal de una persona.
            </p>
          </div>
          <Button
            type="button"
            icono={formAbierto ? ChevronDown : ChevronRight}
            aria-expanded={formAbierto}
            onClick={() => setFormAbierto((anterior) => !anterior)}
          >
            {formAbierto ? "Ocultar formulario" : "Asignar o renovar jornada"}
          </Button>
        </div>

        {exito && (
          <div className="tarjeta-info">
            <CheckCircle2 size={16} aria-hidden="true" />
            <span>
              Jornada asignada a <strong>{exito.nombrePersona}</strong>. Podés asignar otra desde
              acá mismo.
            </span>
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
              disabled={sinPersonas || estadoPersonas === "error"}
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
                <input type="radio" name="tipo_jornada" value="normal" defaultChecked required />
                <span className="texto-opcion">
                  <strong>Normal</strong>
                  <span>Horario fijo, valida tope legal semanal</span>
                </span>
              </label>
              <label className="opcion-seleccionable">
                <input type="radio" name="tipo_jornada" value="flexible" />
                <span className="texto-opcion">
                  <strong>Flexible</strong>
                  <span>Sin tope legal por horario fijo</span>
                </span>
              </label>
              <label className="opcion-seleccionable">
                <input type="radio" name="tipo_jornada" value="de_confianza" />
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
            ayuda="Si la persona ya tiene una jornada vigente, se pedirá confirmar el cierre de esa jornada un día antes de esta fecha."
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
                        required
                      />
                      <Input
                        id={`salida_${valor}`}
                        name={`salida_${valor}`}
                        label="Hora de salida"
                        type="time"
                        required
                      />
                      <Input
                        id={`comida_${valor}`}
                        name={`comida_${valor}`}
                        label="Minutos de comida"
                        type="number"
                        min={0}
                        defaultValue={0}
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
          <a href="/personas">Cancelar</a>
          <Button
            type="submit"
            icono={ArrowRight}
            disabled={formularioDeshabilitado || !!payloadPendiente}
            cargando={enviando && !payloadPendiente}
            textoCargando="Registrando…"
          >
            Registrar
          </Button>
        </div>
      </form>
      )}
      </div>
    </AppShell>
  );
}
