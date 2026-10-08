import { useCallback, useEffect, useState } from "react";
import { AlertCircle, AlertTriangle, CheckCircle2, Loader2, UserPlus } from "lucide-react";

import { Badge } from "./Badge";
import { Button } from "./Button";
import { Input } from "./Input";
import { Modal } from "./Modal";
import { ErrorApi, apiJson, mensajeDeNegocio } from "../lib/errorApi";
import {
  esConflictoDeConsentimiento,
  esConsentimientoCompleto,
  etiquetaPersonaAsignable,
  type Alta,
  type ConsentimientoVigente,
  type PersonaAsignable,
  type RespuestaConsentimiento,
} from "../lib/terminales";

type TerminalRef = { id: number; nombre: string };

type Props = {
  // Desde «Usuarios de la terminal»: la terminal es fija y se elige la persona.
  terminal?: TerminalRef;
  // Desde la ficha de persona: la persona es fija y se elige la terminal.
  terminales?: TerminalRef[];
  personaFija?: PersonaAsignable;
  // persona_id de quien opera (de /api/sesion): sólo para avisar de la auto-asignación; la decisión
  // (excepción del puesto administrador genérico) la toma el backend.
  personaDelCaller?: string | null;
  onCerrar: (refrescar: boolean) => void;
};

type Fase = "editando" | "enviando" | "ok";

const RUTA_CONSENTIMIENTO = "/api/terminales/configuracion/consentimiento";
const MENSAJE_GENERICO = "No se pudo asignar. Inténtalo de nuevo.";
const DEBOUNCE_MS = 300;

export function AsignarPersonaTerminalModal({ terminal, terminales, personaFija, personaDelCaller, onCerrar }: Props) {
  const [vigente, setVigente] = useState<ConsentimientoVigente | null>(null);
  const [estadoTexto, setEstadoTexto] = useState<"cargando" | "listo" | "error">("cargando");
  const [asignables, setAsignables] = useState<PersonaAsignable[]>([]);
  const [busqueda, setBusqueda] = useState("");
  const [busquedaAplicada, setBusquedaAplicada] = useState("");
  const [personaId, setPersonaId] = useState(personaFija?.persona_id ?? "");
  const [terminalId, setTerminalId] = useState(terminal ? String(terminal.id) : "");
  const [confirmado, setConfirmado] = useState(false);
  const [intentoSinCompletar, setIntentoSinCompletar] = useState(false);
  const [fase, setFase] = useState<Fase>("editando");
  const [error, setError] = useState<string | null>(null);
  const [resultado, setResultado] = useState<Pick<Alta, "employee_no"> | null>(null);

  const cargarTexto = useCallback(() => {
    setEstadoTexto("cargando");
    apiJson<RespuestaConsentimiento>(RUTA_CONSENTIMIENTO)
      .then((datos) => {
        setVigente(datos.vigente);
        setEstadoTexto("listo");
      })
      .catch(() => setEstadoTexto("error"));
  }, []);

  useEffect(() => {
    cargarTexto();
  }, [cargarTexto]);

  // Búsqueda con debounce; el servidor exige >= 2 caracteres, con menos se pide la lista inicial.
  useEffect(() => {
    const id = setTimeout(() => setBusquedaAplicada(busqueda.trim().length >= 2 ? busqueda.trim() : ""), DEBOUNCE_MS);
    return () => clearTimeout(id);
  }, [busqueda]);

  useEffect(() => {
    if (personaFija || !terminal) return;
    const params = new URLSearchParams();
    if (busquedaAplicada) params.set("busqueda", busquedaAplicada);
    params.set("limite", "50");
    apiJson<PersonaAsignable[]>(`/api/terminales/${terminal.id}/personas-asignables?${params.toString()}`)
      .then(setAsignables)
      .catch(() => setAsignables([]));
  }, [terminal, personaFija, busquedaAplicada]);

  const enviando = fase === "enviando";
  const personaElegida = personaFija ?? asignables.find((p) => p.persona_id === personaId) ?? null;
  const esPropia = !!personaDelCaller && personaId === personaDelCaller;
  const faltaPersona = intentoSinCompletar && !personaId;
  const faltaTerminal = intentoSinCompletar && !terminalId;
  const faltaConfirmar = intentoSinCompletar && !confirmado;

  async function asignar() {
    setIntentoSinCompletar(true);
    setError(null);
    if (!personaId || !terminalId || !confirmado || !vigente) return;
    setFase("enviando");
    try {
      const alta = await apiJson<Alta>(`/api/terminales/${terminalId}/usuarios`, {
        method: "POST",
        body: JSON.stringify({ persona_id: personaId, consentimiento_id: vigente.id, consentimiento_recabado: true }),
      });
      setResultado({ employee_no: alta.employee_no });
      setFase("ok");
    } catch (fallo) {
      setFase("editando");
      if (fallo instanceof ErrorApi && fallo.status === 409 && fallo.detail) {
        // Cualquier 409 de texto desactualizado: se toma la versión nueva del cuerpo (o se vuelve a
        // pedir) y se pide confirmar otra vez; el servidor nunca acepta una versión vieja.
        const candidato = fallo.cuerpo?.consentimiento_vigente;
        const nuevo = esConsentimientoCompleto(candidato) ? candidato : null;
        if (nuevo) {
          setVigente(nuevo);
          setConfirmado(false);
          setIntentoSinCompletar(false);
        } else if (esConflictoDeConsentimiento(fallo)) {
          setConfirmado(false);
          setIntentoSinCompletar(false);
          cargarTexto();
        }
      }
      setError(mensajeDeNegocio(fallo, MENSAJE_GENERICO));
    }
  }

  if (fase === "ok") {
    return (
      <Modal titulo={<><CheckCircle2 size={22} aria-hidden="true" /> Persona asignada</>} onCancelar={() => onCerrar(true)}>
        <div role="status" style={{ display: "contents" }}>
          <p className="modal__contexto">
            {personaElegida?.nombre ?? "La persona"} quedó en <strong>Pendiente de alta</strong>
            {resultado?.employee_no ? ` (nº ${resultado.employee_no})` : ""}. El puente crea el usuario en el
            aparato y pasa a <strong>Esperando huella</strong>: avisa a TI para enrolar la huella en el menú de
            la terminal. Si nadie la enrola a tiempo, el alta se da de baja sola.
          </p>
        </div>
        <div className="modal__botonera">
          <Button variante="primario" onClick={() => onCerrar(true)}>
            Cerrar
          </Button>
        </div>
      </Modal>
    );
  }

  const contexto = terminal ? (
    <>
      Terminal <strong>{terminal.nombre}</strong>. Se crea el usuario en el aparato; la huella la enrola TI en el
      menú de la terminal, con RH presente.
    </>
  ) : (
    "Se crea el usuario en el aparato; la huella la enrola TI en el menú de la terminal, con RH presente."
  );

  return (
    <Modal titulo="Asignar persona a la terminal" descripcion={contexto} bloqueado={enviando} onCancelar={() => onCerrar(false)}>
      {terminales && (
        <div className={faltaTerminal ? "campo-error" : undefined}>
          <label htmlFor="asignar-terminal">Terminal</label>
          <select
            id="asignar-terminal"
            value={terminalId}
            disabled={enviando}
            aria-invalid={faltaTerminal || undefined}
            onChange={(evento) => setTerminalId(evento.target.value)}
          >
            <option value="">Selecciona una terminal…</option>
            {terminales.map((t) => (
              <option key={t.id} value={t.id}>
                {t.nombre}
              </option>
            ))}
          </select>
          {faltaTerminal && <p className="mensaje-campo">Elige la terminal.</p>}
        </div>
      )}

      {personaFija ? (
        <p style={{ margin: 0 }}>
          <strong>{etiquetaPersonaAsignable(personaFija)}</strong>
        </p>
      ) : (
        <>
          <Input
            id="asignar-buscar"
            label="Buscar persona"
            type="search"
            value={busqueda}
            disabled={enviando}
            onChange={(evento) => setBusqueda(evento.target.value)}
            ayuda="Al menos 2 letras del nombre o apellidos."
          />
          <div className={faltaPersona ? "campo-error" : undefined}>
            <label htmlFor="asignar-persona">Persona (sólo activas, sin alta vigente en esta terminal)</label>
            <select
              id="asignar-persona"
              value={personaId}
              disabled={enviando}
              aria-invalid={faltaPersona || undefined}
              onChange={(evento) => setPersonaId(evento.target.value)}
            >
              <option value="">Selecciona una persona…</option>
              {asignables.map((persona) => (
                <option key={persona.persona_id} value={persona.persona_id}>
                  {etiquetaPersonaAsignable(persona)}
                </option>
              ))}
            </select>
            <p className="ayuda-campo">Se muestra nombre y puesto · área para distinguir homónimos.</p>
            {faltaPersona && (
              <p className="mensaje-campo">
                <AlertCircle size={14} aria-hidden="true" />
                Elige a la persona.
              </p>
            )}
          </div>
        </>
      )}

      {esPropia && (
        <div className="banner-aviso" role="note">
          <AlertTriangle size={16} aria-hidden="true" />
          <div>
            <strong>Te estás asignando a ti.</strong> Sólo el puesto administrador puede hacerlo; si tu puesto no lo
            es, el sistema lo rechazará.
          </div>
        </div>
      )}

      {estadoTexto === "cargando" && (
        <p className="boton-con-icono" role="status">
          <Loader2 size={16} className="icono-girando" aria-hidden="true" />
          Cargando el texto de consentimiento…
        </p>
      )}

      {estadoTexto === "error" && (
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            No se pudo cargar el texto de consentimiento
          </strong>
          <p>Sin el texto vigente no se puede asignar.</p>
          <Button onClick={cargarTexto}>Reintentar</Button>
        </div>
      )}

      {estadoTexto === "listo" && vigente && (
        <div className={`casilla-consentimiento${faltaConfirmar ? " campo-error" : ""}`}>
          <input
            type="checkbox"
            id="asignar-consentimiento"
            checked={confirmado}
            disabled={enviando}
            aria-describedby="asignar-consentimiento-texto"
            onChange={(evento) => setConfirmado(evento.target.checked)}
          />
          <label htmlFor="asignar-consentimiento" style={{ margin: 0, fontWeight: 500, color: "var(--navy)" }}>
            <strong>Consentimiento y aviso de privacidad recabados.</strong>
            <span
              id="asignar-consentimiento-texto"
              style={{ display: "block", fontWeight: 400, color: "var(--navy-medio)", whiteSpace: "pre-line" }}
            >
              {vigente.texto}
            </span>
            <span style={{ display: "block", marginTop: "0.4rem", fontWeight: 400, fontSize: "0.78rem", color: "var(--navy-medio)" }}>
              Texto versión {vigente.version}
              {vigente.provisional && (
                <>
                  {" "}
                  <Badge variante="aviso">Provisional — pendiente del texto definitivo de RH/Legal</Badge>
                </>
              )}
            </span>
          </label>
        </div>
      )}
      {faltaConfirmar && estadoTexto === "listo" && (
        <p className="mensaje-campo">
          <AlertCircle size={14} aria-hidden="true" />
          Confirma que el consentimiento está recabado para poder asignar.
        </p>
      )}

      {error && (
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            No se asignó
          </strong>
          <p>{error}</p>
        </div>
      )}

      <div className="modal__botonera">
        <Button disabled={enviando} onClick={() => onCerrar(false)}>
          Cancelar
        </Button>
        <Button
          variante="primario"
          icono={UserPlus}
          posicionIcono="izquierda"
          cargando={enviando}
          textoCargando="Asignando…"
          disabled={estadoTexto !== "listo"}
          onClick={asignar}
        >
          Asignar
        </Button>
      </div>
    </Modal>
  );
}
