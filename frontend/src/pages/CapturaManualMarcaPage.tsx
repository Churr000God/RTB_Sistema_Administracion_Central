import { type FormEvent, useEffect, useState } from "react";
import { CheckCircle2, Fingerprint, Info } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { generarUuidV4 } from "../lib/uuid";
import { etiquetaMotivo } from "../lib/motivosRevision";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { Input } from "../components/Input";

// Punto de captura fijo por estación de RH (SCJ-PRO-07 §II.3: "terminal_id" identifica el
// aparato O el punto de captura, no hace falta un picker — candidato del propio proceso).
const TERMINAL_ID = "rh-captura-01";

type Persona = {
  id: string;
  primer_nombre: string;
  apellido_paterno: string;
  estado: string;
};

type EstadoCatalogo = "cargando" | "listo" | "error";

type ResultadoCaptura = {
  evento_id: string;
  momento_dispositivo: string;
  momento_recepcion: string;
  requiere_revision: boolean;
  motivos_revision: string[];
  duplicado?: boolean;
};

// input[type=datetime-local] no lleva zona horaria — se interpreta como hora local del
// navegador, que es justo lo que queremos capturar (momento real del evento, no UTC).
function ahoraParaDatetimeLocal(): string {
  const ahora = new Date();
  ahora.setSeconds(0, 0);
  ahora.setMinutes(ahora.getMinutes() - ahora.getTimezoneOffset());
  return ahora.toISOString().slice(0, 16);
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

function formatearHoraServidor(fecha: string): string {
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return fecha;
  return valor.toLocaleString("es-MX", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

export function CapturaManualMarcaPage() {
  const [personas, setPersonas] = useState<Persona[]>([]);
  const [estadoPersonas, setEstadoPersonas] = useState<EstadoCatalogo>("cargando");
  const [personaId, setPersonaId] = useState("");
  // A2 del proceso (SCJ-ESP-01 §VII.4): el evento_id nace al MONTAR el formulario, no al
  // enviarlo — es la llave de idempotencia. Si el usuario reintenta sin refrescar, se reenvía
  // el mismo evento_id en vez de generar uno nuevo (evita marcas duplicadas por doble clic o
  // reintento de red).
  const [eventoId, setEventoId] = useState(() => generarUuidV4());
  const [momentoDispositivo, setMomentoDispositivo] = useState(() => ahoraParaDatetimeLocal());
  const [error, setError] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);
  const [resultado, setResultado] = useState<ResultadoCaptura | null>(null);

  useEffect(() => {
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
  }, []);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    setEnviando(true);
    try {
      const respuesta = await apiFetch("/api/marcas/captura-manual", {
        method: "POST",
        body: JSON.stringify({
          evento_id: eventoId,
          persona_id: personaId,
          terminal_id: TERMINAL_ID,
          momento_dispositivo: new Date(momentoDispositivo).toISOString(),
        }),
      });
      if (!respuesta.ok) {
        setError(await mensajeDeError(respuesta, "No se pudo registrar la marca."));
        return;
      }
      const cuerpo: ResultadoCaptura = await respuesta.json();
      setResultado(cuerpo);
    } catch {
      // Sin esto, una excepción de red dejaba el botón en "Registrando…" para siempre —
      // mismo bug ya encontrado y corregido en AsignarJornadaPage.
      setError("No se pudo registrar la marca. Revisa tu conexión e intenta de nuevo.");
    } finally {
      setEnviando(false);
    }
  }

  function handleRegistrarOtra() {
    setResultado(null);
    setPersonaId("");
    setError(null);
    // Nueva captura = nuevo evento_id. El anterior ya sirvió su propósito de idempotencia.
    setEventoId(generarUuidV4());
    setMomentoDispositivo(ahoraParaDatetimeLocal());
  }

  const sinPersonas = estadoPersonas === "listo" && personas.length === 0;
  const formularioDeshabilitado = sinPersonas || estadoPersonas === "error";

  return (
    <AppShell>
      <div className="contenedor-pagina">
        <nav className="migas">
          <strong>Captura manual de marca</strong>
        </nav>
        <h1>Captura manual de marca</h1>
        <p className="subtitulo-pagina">
          Registra la entrada o salida de una persona que no marcó por terminal, con el momento
          real en que ocurrió el evento — la captura admite hasta unos días hábiles hacia atrás,
          nunca una hora futura.
        </p>

        {resultado ? (
          <Card>
            <p className="boton-con-icono">
              <CheckCircle2 size={18} aria-hidden="true" />
              {resultado.duplicado ? "Ya estaba registrada" : "Marca registrada"} · ocurrió:{" "}
              <strong>{formatearHoraServidor(resultado.momento_dispositivo)}</strong> · recibida
              por el servidor: <strong>{formatearHoraServidor(resultado.momento_recepcion)}</strong>
            </p>
            {resultado.requiere_revision && (
              <div className="tarjeta-info">
                <Info size={16} aria-hidden="true" />
                <span>
                  Quedó marcada para revisión
                  {resultado.motivos_revision.length > 0 ? (
                    <>
                      :{" "}
                      {resultado.motivos_revision.map((motivo) => etiquetaMotivo(motivo)).join(", ")}
                      .
                    </>
                  ) : (
                    " (motivo no especificado)."
                  )}{" "}
                  La marca ya está registrada — esto sólo la señala para que alguien la revise
                  después.
                </span>
              </div>
            )}
            <div className="botonera">
              <Button type="button" variante="primario" onClick={handleRegistrarOtra}>
                Registrar otra marca
              </Button>
            </div>
          </Card>
        ) : (
          <form onSubmit={handleSubmit} className="contenedor-pagina">
            <fieldset className="fieldset-formulario">
              <legend className="encabezado-fieldset">
                <span className="icono-seccion">
                  <Fingerprint size={16} aria-hidden="true" />
                </span>
                Datos de la marca
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
                    No hay personas activas para marcar.
                  </small>
                )}
                {estadoPersonas === "error" && (
                  <small className="ayuda-campo" id="persona_id-ayuda">
                    No se pudo cargar el padrón de personas.
                  </small>
                )}
              </div>

              <Input
                id="momento_dispositivo"
                label="Momento del evento"
                type="datetime-local"
                required
                value={momentoDispositivo}
                onChange={(evento) => setMomentoDispositivo(evento.target.value)}
                ayuda="La hora real en que ocurrió la entrada o salida — no futura, ni más atrás de la ventana de días hábiles permitida."
              />
            </fieldset>

            {error && <p role="alert">{error}</p>}
            <div className="botonera">
              <Button
                type="submit"
                variante="primario"
                disabled={formularioDeshabilitado || !personaId}
                cargando={enviando}
                textoCargando="Registrando…"
              >
                Confirmar marca
              </Button>
            </div>
          </form>
        )}
      </div>
    </AppShell>
  );
}
