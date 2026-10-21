import { useEffect, useId, useRef, useState } from "react";
import { AlertCircle, AlertTriangle, CheckCircle2, Trash2 } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { formatearHoraMexico } from "../lib/calendario";
import { Button } from "./Button";

export const MIN_MOTIVO_ALERTA = 10;
export const MAX_MOTIVO_ALERTA = 500;

export type MarcaConAlertaHorario = {
  // Id de la excepción de horario (NO el de la excepción pendiente de la marca, que puede ser otra).
  excepcionHorarioId: number;
  persona_nombre: string | null;
  momento_efectivo: string | null;
};

type Props = {
  marca: MarcaConAlertaHorario;
  // refrescar=true cuando la lista cambió (descartó o hubo un 409: ya no es lo que se veía).
  onCerrar: (refrescar: boolean) => void;
};

type Fase = "editando" | "enviando" | "descartada";

// Los errores de negocio de backend (403 permiso o alerta propia, 404, 409, 422) traen un `detail`
// fijo y legible: se muestra tal cual. Solo si no hay detail, o es otro status, se usa el respaldo.
const MENSAJE_GENERICO = "No se pudo completar. Inténtalo de nuevo.";
const MENSAJE_RESPALDO: Record<number, string> = {
  403: "No tienes permiso para esta acción.",
  404: "No se encontró la alerta.",
  409: "La alerta cambió de estado. Actualiza la lista para ver su situación actual.",
  422: `El motivo debe tener entre ${MIN_MOTIVO_ALERTA} y ${MAX_MOTIVO_ALERTA} caracteres.`,
  503: "Servicio no disponible; reintenta.",
};

function formatearMarca(momento: string | null): string {
  if (!momento) return "—";
  const valor = new Date(momento);
  if (Number.isNaN(valor.getTime())) return "—";
  return formatearHoraMexico(valor, {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

async function leerDetalle(respuesta: Response): Promise<string | null> {
  try {
    const cuerpo = await respuesta.json();
    return typeof cuerpo?.detail === "string" ? cuerpo.detail : null;
  } catch {
    return null;
  }
}

// Mismo patrón que DescartarMarcaTardiaModal: <dialog> nativo con showModal(). Descartar la alerta
// «Fuera de horario» de un día cerrado o revisado no cambia horas ni la marca: solo cierra la alerta
// con constancia (quién y por qué) en una bitácora inmutable. El motivo nunca se pinta como HTML.
export function DescartarAlertaHorarioModal({ marca, onCerrar }: Props) {
  const dialogoRef = useRef<HTMLDialogElement>(null);
  const idTitulo = useId();
  const idContexto = useId();
  const idError = useId();
  const [motivo, setMotivo] = useState("");
  const [fase, setFase] = useState<Fase>("editando");
  const [errorCampo, setErrorCampo] = useState(false);
  const [errorServidor, setErrorServidor] = useState<{ texto: string; conflicto: boolean } | null>(null);
  // Candado síncrono: dos clics seguidos antes de que React repinte no deben enviar dos veces.
  const enviandoRef = useRef(false);

  useEffect(() => {
    const dialogo = dialogoRef.current;
    if (dialogo && !dialogo.open) dialogo.showModal();
  }, []);

  function cerrar(refrescar: boolean) {
    dialogoRef.current?.close();
    onCerrar(refrescar);
  }

  const enviando = fase === "enviando";
  const terminado = fase === "descartada";

  async function descartar() {
    if (enviandoRef.current) return;
    const texto = motivo.trim();
    if (texto.length < MIN_MOTIVO_ALERTA || texto.length > MAX_MOTIVO_ALERTA) {
      setErrorCampo(true);
      return;
    }
    enviandoRef.current = true;
    setErrorCampo(false);
    setErrorServidor(null);
    setFase("enviando");
    try {
      const respuesta = await apiFetch(
        `/api/excepciones/${marca.excepcionHorarioId}/descartar-alerta-horario`,
        { method: "POST", body: JSON.stringify({ motivo: texto }) },
      );
      if (respuesta.ok) {
        setFase("descartada");
        return;
      }
      const detalle = await leerDetalle(respuesta);
      setErrorServidor({
        texto: detalle ?? MENSAJE_RESPALDO[respuesta.status] ?? MENSAJE_GENERICO,
        conflicto: respuesta.status === 409,
      });
    } catch {
      setErrorServidor({ texto: "No se pudo completar. Revisa tu conexión e inténtalo de nuevo.", conflicto: false });
    } finally {
      enviandoRef.current = false;
    }
    setFase((actual) => (actual === "descartada" ? actual : "editando"));
  }

  return (
    <dialog
      ref={dialogoRef}
      className="modal"
      aria-labelledby={idTitulo}
      aria-describedby={idContexto}
      onCancel={(evento) => {
        evento.preventDefault();
        if (!enviando) cerrar(terminado);
      }}
    >
      {terminado ? (
        <div role="status" style={{ display: "contents" }}>
          <h2 id={idTitulo} className="boton-con-icono" style={{ justifyContent: "flex-start" }}>
            <CheckCircle2 size={22} aria-hidden="true" /> Alerta descartada
          </h2>
          <p className="modal__contexto" id={idContexto}>
            La alerta de horario de {marca.persona_nombre ?? "la persona"} quedó descartada y registrada con tu
            nombre y el motivo indicado. La marca y las horas del día no cambiaron.
          </p>
          <div className="modal__botonera">
            <Button variante="primario" onClick={() => cerrar(true)}>
              Cerrar
            </Button>
          </div>
        </div>
      ) : (
        <>
          <h2 id={idTitulo}>Descartar alerta de horario</h2>
          <p className="modal__contexto" id={idContexto}>
            Marca de <strong>{marca.persona_nombre ?? "—"}</strong> · {formatearMarca(marca.momento_efectivo)}.
            Esta marca ya está contada en el día: descartar solo cierra la alerta «Fuera de horario» con
            constancia; no cambia la marca ni las horas.
          </p>
          <div className="modal__advertencia" role="note">
            <AlertTriangle size={16} aria-hidden="true" />
            <div>
              <strong>Esta acción no se puede deshacer.</strong> Queda en una bitácora quién descartó la alerta y
              el motivo que escribas aquí.
            </div>
          </div>
          <div className={errorCampo ? "campo-error" : undefined}>
            <label htmlFor={`${idTitulo}-motivo`}>Motivo del descarte (obligatorio)</label>
            <textarea
              id={`${idTitulo}-motivo`}
              rows={4}
              maxLength={MAX_MOTIVO_ALERTA}
              value={motivo}
              aria-invalid={errorCampo || undefined}
              aria-describedby={errorCampo ? idError : `${idTitulo}-nota`}
              disabled={enviando}
              onChange={(evento) => {
                setMotivo(evento.target.value);
                if (errorCampo) setErrorCampo(false);
              }}
            />
            <small className="ayuda-campo" id={`${idTitulo}-nota`}>
              No escribas datos médicos ni sensibles.
            </small>
            {errorCampo && (
              <p className="mensaje-campo" id={idError}>
                <AlertCircle size={14} aria-hidden="true" />
                Escribe un motivo (entre {MIN_MOTIVO_ALERTA} y {MAX_MOTIVO_ALERTA} caracteres).
              </p>
            )}
            <div className="modal__contador num">
              {motivo.length} / {MAX_MOTIVO_ALERTA}
            </div>
          </div>
          {errorServidor && (
            <div className="tarjeta-error" role="alert">
              <strong>
                <AlertCircle size={16} aria-hidden="true" />
                No se descartó la alerta
              </strong>
              <p>{errorServidor.texto}</p>
            </div>
          )}
          <div className="modal__botonera">
            <Button disabled={enviando} onClick={() => cerrar(false)}>
              Cancelar
            </Button>
            {errorServidor?.conflicto ? (
              <Button variante="primario" onClick={() => cerrar(true)}>
                Actualizar lista
              </Button>
            ) : (
              <Button
                className="boton-peligro"
                icono={Trash2}
                posicionIcono="izquierda"
                cargando={enviando}
                textoCargando="Descartando…"
                onClick={descartar}
              >
                Descartar alerta
              </Button>
            )}
          </div>
        </>
      )}
    </dialog>
  );
}
