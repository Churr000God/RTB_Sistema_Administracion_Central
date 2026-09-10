import { type FormEvent, useEffect, useMemo, useState } from "react";
import { AlertCircle, Loader2 } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { fechaASemanaIso, semanaIsoALunes } from "../lib/semanaIso";
import { Badge } from "../components/Badge";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { Input } from "../components/Input";

type Vigencia = {
  id: number;
  vigente_desde: string;
  vigente_hasta: string | null;
  maximo_semanal: number;
  maximo_extra: number;
};

type PayloadTope = {
  vigente_desde: string;
  maximo_semanal: number;
  maximo_extra: number;
  confirma_cierre_vigente?: boolean;
};

type PersonaExceso = {
  persona_id: string;
  persona_nombre: string | null;
  horas_ordinarias: number;
  horas_extra: number;
  horas_reposicion: number;
  supera_semanal: boolean;
  supera_extra: boolean;
  supera_combinado: boolean;
  exceso_semanal: number;
  exceso_extra: number;
  exceso_combinado: number;
};

type RespuestaExceso = {
  semana_desde: string;
  semana_hasta: string;
  maximo_semanal: number | null;
  maximo_extra: number | null;
  personas: PersonaExceso[];
};

type EstadoCarga = "cargando" | "listo" | "error";

function formatearFecha(fecha?: string | null): string {
  if (!fecha) return "—";
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

export function ParametrosTopeLegalPage() {
  const [historial, setHistorial] = useState<Vigencia[]>([]);
  const [estadoHistorial, setEstadoHistorial] = useState<EstadoCarga>("cargando");
  const [error, setError] = useState<string | null>(null);
  const [guardando, setGuardando] = useState(false);
  const [payloadPendiente, setPayloadPendiente] = useState<PayloadTope | null>(null);
  // Fuerza el remount del form para limpiar los inputs no controlados después de guardar —
  // mismo recurso que AsignarJornadaPage.
  const [formKey, setFormKey] = useState(0);

  const [semanaSeleccionada, setSemanaSeleccionada] = useState(() => fechaASemanaIso(new Date()));
  const [exceso, setExceso] = useState<RespuestaExceso | null>(null);
  const [estadoExceso, setEstadoExceso] = useState<EstadoCarga>("cargando");

  function cargarHistorial() {
    setEstadoHistorial("cargando");
    apiFetch("/api/tope-legal")
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datos: Vigencia[]) => {
        setHistorial(datos);
        setEstadoHistorial("listo");
      })
      .catch(() => setEstadoHistorial("error"));
  }

  useEffect(cargarHistorial, []);

  const lunesSeleccionado = useMemo(() => semanaIsoALunes(semanaSeleccionada), [semanaSeleccionada]);

  function cargarExceso() {
    if (!lunesSeleccionado) return;
    setEstadoExceso("cargando");
    apiFetch(`/api/tope-legal/exceso-semanal?semana_de=${lunesSeleccionado}`)
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datos: RespuestaExceso) => {
        setExceso(datos);
        setEstadoExceso("listo");
      })
      .catch(() => setEstadoExceso("error"));
  }

  useEffect(cargarExceso, [lunesSeleccionado]);

  async function enviarTope(payload: PayloadTope) {
    setGuardando(true);
    try {
      const respuesta = await apiFetch("/api/tope-legal", {
        method: "POST",
        body: JSON.stringify(payload),
      });
      if (respuesta.ok) {
        setPayloadPendiente(null);
        setError(null);
        setFormKey((anterior) => anterior + 1);
        cargarHistorial();
        cargarExceso(); // el tope recién guardado puede cambiar quién excede la semana vista
        return;
      }
      if (respuesta.status === 409 && !payload.confirma_cierre_vigente) {
        setPayloadPendiente(payload);
        return;
      }
      setError(await mensajeDeError(respuesta, "No se pudo guardar el nuevo tope legal."));
      setPayloadPendiente(null);
    } catch {
      setError("No se pudo guardar el nuevo tope legal. Revisa tu conexión e intenta de nuevo.");
      setPayloadPendiente(null);
    } finally {
      setGuardando(false);
    }
  }

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    setPayloadPendiente(null);
    const f = new FormData(evento.currentTarget);
    await enviarTope({
      vigente_desde: String(f.get("vigente_desde")),
      maximo_semanal: Number(f.get("maximo_semanal")),
      maximo_extra: Number(f.get("maximo_extra")),
    });
  }

  function handleConfirmarCierre() {
    if (!payloadPendiente) return;
    enviarTope({ ...payloadPendiente, confirma_cierre_vigente: true });
  }

  function handleCancelarCierre() {
    setPayloadPendiente(null);
  }

  const vigente = historial.find((v) => v.vigente_hasta === null) ?? null;
  const historialOrdenado = [...historial].sort((a, b) => b.vigente_desde.localeCompare(a.vigente_desde));

  const personasOrdenadas = useMemo(() => {
    if (!exceso) return [];
    return [...exceso.personas].sort(
      (a, b) =>
        b.exceso_semanal + b.exceso_extra + b.exceso_combinado -
        (a.exceso_semanal + a.exceso_extra + a.exceso_combinado),
    );
  }, [exceso]);

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <strong>Tope legal</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Tope legal</h1>
            <p className="subtitulo-pagina">
              Tope semanal de horas ordinarias y de horas extra, y quién lo supera cada semana.
            </p>
          </div>
        </div>

        <Card>
          <h3>Vigencia actual</h3>
          {estadoHistorial === "cargando" && (
            <p className="boton-con-icono">
              <Loader2 size={16} className="icono-girando" aria-hidden="true" />
              Cargando…
            </p>
          )}
          {estadoHistorial === "error" && (
            <div className="tarjeta-error" role="alert">
              <strong>
                <AlertCircle size={16} aria-hidden="true" />
                No se pudo cargar el historial de tope legal
              </strong>
              <button type="button" onClick={cargarHistorial}>
                Reintentar
              </button>
            </div>
          )}
          {estadoHistorial === "listo" && (
            <>
              {vigente ? (
                <p className="meta-ficha">
                  <span className="insignia insignia--exito">
                    Vigente desde {formatearFecha(vigente.vigente_desde)}
                  </span>{" "}
                  · {vigente.maximo_semanal} h semanales / {vigente.maximo_extra} h extra
                </p>
              ) : (
                <p>No hay un tope legal vigente ahora mismo.</p>
              )}

              <form key={formKey} onSubmit={handleSubmit} className="fieldset-formulario">
                <div className="rejilla-campos">
                  <Input
                    id="maximo_semanal"
                    name="maximo_semanal"
                    label="Máximo semanal (h)"
                    type="number"
                    min={0}
                    step="0.5"
                    required
                    defaultValue={vigente?.maximo_semanal}
                  />
                  <Input
                    id="maximo_extra"
                    name="maximo_extra"
                    label="Máximo de horas extra (h)"
                    type="number"
                    min={0}
                    step="0.5"
                    required
                    defaultValue={vigente?.maximo_extra}
                  />
                  <Input id="vigente_desde" name="vigente_desde" label="Vigente desde" type="date" required />
                </div>

                {payloadPendiente && (
                  <Card>
                    <p role="alert">
                      Ya hay un tope legal vigente desde {formatearFecha(vigente?.vigente_desde)}. ¿Cerrarlo
                      y dejar vigente el nuevo desde {payloadPendiente.vigente_desde}?
                    </p>
                    <div className="botonera">
                      <Button type="button" onClick={handleCancelarCierre}>
                        Cancelar
                      </Button>
                      <Button
                        type="button"
                        variante="primario"
                        cargando={guardando}
                        textoCargando="Cerrando y guardando…"
                        onClick={handleConfirmarCierre}
                      >
                        Sí, cerrar el anterior y guardar
                      </Button>
                    </div>
                  </Card>
                )}

                {error && <p role="alert">{error}</p>}
                <div className="botonera">
                  <Button
                    type="submit"
                    variante="primario"
                    disabled={!!payloadPendiente}
                    cargando={guardando && !payloadPendiente}
                    textoCargando="Guardando…"
                  >
                    Guardar nuevo tope
                  </Button>
                </div>
              </form>

              <p className="eyebrow-seccion">Historial</p>
              {historialOrdenado.length === 0 ? (
                <p>Sin vigencias registradas todavía.</p>
              ) : (
                <ul className="lista-historial-resumido">
                  {historialOrdenado.map((v) => (
                    <li key={v.id}>
                      <span className="fecha-historial">
                        {formatearFecha(v.vigente_desde)} – {v.vigente_hasta ? formatearFecha(v.vigente_hasta) : "hoy"}
                      </span>
                      <span>
                        {v.maximo_semanal} h / {v.maximo_extra} h
                      </span>
                    </li>
                  ))}
                </ul>
              )}
            </>
          )}
        </Card>

        <Card>
          <h3>Personas que superan el tope legal</h3>
          <Input
            id="semana-exceso"
            label="Semana"
            type="week"
            value={semanaSeleccionada}
            onChange={(evento) => setSemanaSeleccionada(evento.target.value)}
          />

          {estadoExceso === "cargando" && (
            <p className="boton-con-icono">
              <Loader2 size={16} className="icono-girando" aria-hidden="true" />
              Cargando…
            </p>
          )}

          {estadoExceso === "error" && (
            <div className="tarjeta-error" role="alert">
              <strong>
                <AlertCircle size={16} aria-hidden="true" />
                No se pudo cargar el exceso de la semana
              </strong>
              <button type="button" onClick={cargarExceso}>
                Reintentar
              </button>
            </div>
          )}

          {estadoExceso === "listo" && exceso && exceso.maximo_semanal == null && (
            <div className="estado-vacio">
              <p>No hay un tope legal configurado para esta semana.</p>
            </div>
          )}

          {estadoExceso === "listo" && exceso && exceso.maximo_semanal != null && (
            <>
              <p className="meta-ficha">
                Tope semanal vigente: {exceso.maximo_semanal} h · Tope de horas extra: {exceso.maximo_extra} h
              </p>

              {personasOrdenadas.length === 0 ? (
                <div className="estado-vacio">
                  <p>Nadie superó el tope legal esta semana.</p>
                </div>
              ) : (
                <div className="tabla-desplazable">
                  <table>
                    <thead>
                      <tr>
                        <th>Persona</th>
                        <th>Horas ordinarias</th>
                        <th>Horas extra</th>
                        <th>Horas reposición</th>
                        <th>Motivo</th>
                      </tr>
                    </thead>
                    <tbody>
                      {personasOrdenadas.map((p) => (
                        <tr key={p.persona_id}>
                          <td>{p.persona_nombre ?? "—"}</td>
                          <td>{p.horas_ordinarias.toFixed(1)}</td>
                          <td>{p.horas_extra.toFixed(1)}</td>
                          <td>{p.horas_reposicion.toFixed(1)}</td>
                          <td>
                            <div className="grupo-insignias">
                              {p.supera_semanal && (
                                <Badge variante="peligro">Semanal (+{p.exceso_semanal.toFixed(1)} h)</Badge>
                              )}
                              {p.supera_extra && (
                                <Badge variante="peligro">Extra (+{p.exceso_extra.toFixed(1)} h)</Badge>
                              )}
                              {p.supera_combinado && (
                                <Badge variante="peligro">Combinado (+{p.exceso_combinado.toFixed(1)} h)</Badge>
                              )}
                            </div>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </>
          )}
        </Card>
      </div>
    </AppShell>
  );
}
