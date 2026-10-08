import { useState } from "react";
import { AlertCircle, AlertTriangle, CheckCircle2, Trash2 } from "lucide-react";

import { Badge } from "./Badge";
import { Button } from "./Button";
import { Modal } from "./Modal";
import { ErrorApi, apiJson, mensajeDeNegocio } from "../lib/errorApi";

const MIN_MOTIVO = 10;
const MAX_MOTIVO = 500;
const MENSAJE_GENERICO = "No se pudo completar. Inténtalo de nuevo.";

type Props = {
  terminalId: number;
  alta: { id: number; persona_nombre: string | null; employee_no: number };
  accion: "cancelar_alta" | "dar_de_baja";
  onCerrar: (refrescar: boolean) => void;
};

type Fase = "editando" | "enviando" | "ok";

// Mismo saneo que el servidor aplica antes de medir: espacios colapsados y recortados.
function sanear(texto: string): string {
  return texto.replace(/\s+/g, " ").trim();
}

// «Cancelar alta» (pendiente_alta / esperando_huella) y «Dar de baja» (activo) son el MISMO
// endpoint: la diferencia es sólo el estado de origen (accion_disponible) y el texto.
export function BajaAltaModal({ terminalId, alta, accion, onCerrar }: Props) {
  const cancelar = accion === "cancelar_alta";
  const [motivo, setMotivo] = useState("");
  const [fase, setFase] = useState<Fase>("editando");
  const [campoInvalido, setCampoInvalido] = useState(false);
  const [error, setError] = useState<{ texto: string; conflicto: boolean } | null>(null);
  const enviando = fase === "enviando";

  async function solicitar() {
    const limpio = sanear(motivo);
    if (limpio.length < MIN_MOTIVO || limpio.length > MAX_MOTIVO) {
      setCampoInvalido(true);
      return;
    }
    setCampoInvalido(false);
    setError(null);
    setFase("enviando");
    try {
      await apiJson(`/api/terminales/${terminalId}/usuarios/${alta.id}/baja`, {
        method: "POST",
        body: JSON.stringify({ motivo: limpio }),
      });
      setFase("ok");
    } catch (fallo) {
      setFase("editando");
      setError({
        texto: mensajeDeNegocio(fallo, MENSAJE_GENERICO),
        conflicto: fallo instanceof ErrorApi && fallo.status === 409,
      });
    }
  }

  if (fase === "ok") {
    return (
      <Modal
        titulo={<><CheckCircle2 size={22} aria-hidden="true" /> {cancelar ? "Alta cancelada" : "Baja solicitada"}</>}
        onCancelar={() => onCerrar(true)}
      >
        <div role="status" style={{ display: "contents" }}>
          <p className="modal__contexto">
            El alta quedó en <strong>Pendiente de baja</strong>. Cuando el puente borre el usuario del aparato pasará a{" "}
            <strong>Baja</strong>; es el asiento de que el dato biométrico dejó de tratarse.
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

  return (
    <Modal
      titulo={cancelar ? "Cancelar alta" : "Dar de baja"}
      descripcion={
        <>
          {alta.persona_nombre ?? "—"} · nº {alta.employee_no}{" "}
          <Badge variante={cancelar ? "info" : "exito"}>{cancelar ? "En proceso de alta" : "Activo"}</Badge>
        </>
      }
      bloqueado={enviando}
      onCancelar={() => onCerrar(false)}
    >
      <div className="modal__advertencia" role="note">
        <AlertTriangle size={16} aria-hidden="true" />
        <div>
          {cancelar ? (
            <>
              <strong>El alta se cancela y el usuario se borra del aparato.</strong> Para volver a enrolar a la
              persona hay que asignarla de nuevo (otro número, nuevo consentimiento si lo revocó).
            </>
          ) : (
            <>
              <strong>El puente borrará el usuario y sus huellas del aparato.</strong> Es irreversible. Hasta que se
              confirme, la persona todavía puede marcar. Para volver a enrolarla hay que asignarla de nuevo y TI debe
              enrolar su huella otra vez.
            </>
          )}
        </div>
      </div>

      <div className={campoInvalido ? "campo-error" : undefined}>
        <label htmlFor="baja-motivo">Motivo (obligatorio, mínimo {MIN_MOTIVO} caracteres)</label>
        <textarea
          id="baja-motivo"
          rows={3}
          required
          aria-required="true"
          maxLength={MAX_MOTIVO}
          value={motivo}
          disabled={enviando}
          aria-invalid={campoInvalido || undefined}
          aria-describedby={campoInvalido ? "baja-motivo-error baja-motivo-contador" : "baja-motivo-contador"}
          placeholder="Ej.: la persona revocó su consentimiento."
          onChange={(evento) => {
            setMotivo(evento.target.value);
            if (campoInvalido) setCampoInvalido(false);
          }}
        />
        {campoInvalido && (
          <p className="mensaje-campo" id="baja-motivo-error">
            <AlertCircle size={14} aria-hidden="true" />
            Escribe el motivo de la baja (al menos {MIN_MOTIVO} caracteres).
          </p>
        )}
        <div className="modal__contador num" id="baja-motivo-contador">
          {motivo.length} / {MAX_MOTIVO} · mínimo {MIN_MOTIVO}
        </div>
      </div>

      {error && (
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            {cancelar ? "No se canceló el alta" : "No se dio de baja"}
          </strong>
          <p>{error.texto}</p>
        </div>
      )}

      <div className="modal__botonera">
        <Button disabled={enviando} onClick={() => onCerrar(false)}>
          Volver
        </Button>
        {error?.conflicto && (
          <Button variante="primario" onClick={() => onCerrar(true)}>
            Actualizar lista
          </Button>
        )}
        <Button
          className="boton-peligro"
          icono={Trash2}
          posicionIcono="izquierda"
          cargando={enviando}
          textoCargando="Solicitando baja…"
          onClick={solicitar}
        >
          {cancelar ? "Cancelar el alta" : "Dar de baja definitivamente"}
        </Button>
      </div>
    </Modal>
  );
}
