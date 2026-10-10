import { useState } from "react";
import { AlertCircle, AlertTriangle, CheckCircle2 } from "lucide-react";

import { Badge } from "./Badge";
import { Button } from "./Button";
import { Modal } from "./Modal";
import { ErrorApi, apiJson, mensajeDeNegocio } from "../lib/errorApi";

export const MIN_NOTA_HUELLA = 10;
export const MAX_NOTA_HUELLA = 500;
const MENSAJE_GENERICO = "No se pudo completar. Inténtalo de nuevo.";

type Props = {
  terminalId: number;
  terminalNombre?: string;
  alta: { id: number; persona_nombre: string | null; employee_no: number };
  onCerrar: (refrescar: boolean) => void;
};

type Fase = "editando" | "enviando" | "ok";

// Mismo saneo que el servidor aplica antes de medir: espacios colapsados y recortados.
function sanear(texto: string): string {
  return texto.replace(/\s+/g, " ").trim();
}

// «Confirmar huella» (SCJ-DEC-12, sin conteo): una persona con terminal_usuario_edicion atestigua que vio la
// huella en el menú del aparato. No se deshace: la bitácora es inmutable. Los errores muestran el `detail` fijo
// del servidor como texto plano.
export function ConfirmarHuellaModal({ terminalId, terminalNombre, alta, onCerrar }: Props) {
  const [nota, setNota] = useState("");
  const [fase, setFase] = useState<Fase>("editando");
  const [campoInvalido, setCampoInvalido] = useState(false);
  const [error, setError] = useState<{ texto: string; conflicto: boolean } | null>(null);
  const enviando = fase === "enviando";

  async function confirmar() {
    const limpia = sanear(nota);
    if (limpia.length < MIN_NOTA_HUELLA || limpia.length > MAX_NOTA_HUELLA) {
      setCampoInvalido(true);
      return;
    }
    setCampoInvalido(false);
    setError(null);
    setFase("enviando");
    try {
      await apiJson(`/api/terminales/${terminalId}/usuarios/${alta.id}/huella-confirmada`, {
        method: "POST",
        body: JSON.stringify({ nota: limpia }),
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
        titulo={<><CheckCircle2 size={22} aria-hidden="true" /> Huella confirmada</>}
        onCancelar={() => onCerrar(true)}
      >
        <div role="status" style={{ display: "contents" }}>
          <p className="modal__contexto">
            {alta.persona_nombre ?? "La persona"} quedó <strong>Activo</strong> con la evidencia «Huella confirmada por
            una persona (sin conteo)». Tu nombre y tu nota quedaron en el historial del alta.
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
      titulo="Confirmar huella"
      descripcion={
        <>
          {alta.persona_nombre ?? "—"} · nº {alta.employee_no}
          {terminalNombre ? ` · ${terminalNombre}` : ""} <Badge variante="info">Esperando huella</Badge>
        </>
      }
      bloqueado={enviando}
      onCancelar={() => onCerrar(false)}
    >
      <div className="modal__advertencia" role="note">
        <AlertTriangle size={16} aria-hidden="true" />
        <div>
          <strong>Estás atestiguando que viste la huella de esta persona en el menú del aparato.</strong> La terminal no
          informa cuántas huellas hay, así que el sistema no puede comprobarlo: tu confirmación (con tu nombre y tu nota)
          queda como la evidencia. <strong>No se puede deshacer.</strong> La bitácora es inmutable; si te equivocas, el
          camino es dar de baja el alta y crear una nueva.
        </div>
      </div>

      <div className={campoInvalido ? "campo-error" : undefined}>
        <label htmlFor="huella-nota">Nota (obligatoria, mínimo {MIN_NOTA_HUELLA} caracteres)</label>
        <textarea
          id="huella-nota"
          rows={3}
          required
          aria-required="true"
          maxLength={MAX_NOTA_HUELLA}
          value={nota}
          disabled={enviando}
          aria-invalid={campoInvalido || undefined}
          aria-describedby={campoInvalido ? "huella-nota-error huella-nota-ayuda huella-nota-contador" : "huella-nota-ayuda huella-nota-contador"}
          placeholder="Ej.: TI enroló el índice derecho en el menú del aparato, presente RH."
          onChange={(evento) => {
            setNota(evento.target.value);
            if (campoInvalido) setCampoInvalido(false);
          }}
        />
        {campoInvalido && (
          <p className="mensaje-campo" id="huella-nota-error">
            <AlertCircle size={14} aria-hidden="true" />
            Escribe una nota de al menos {MIN_NOTA_HUELLA} caracteres.
          </p>
        )}
        <div className="modal__contador num" id="huella-nota-contador">
          {nota.length} / {MAX_NOTA_HUELLA} · mínimo {MIN_NOTA_HUELLA}
        </div>
        <p className="ayuda-campo" id="huella-nota-ayuda" style={{ margin: "0.3rem 0 0" }}>
          No escribas datos personales, solo cómo verificaste la huella (por ejemplo: «la vi en el menú del aparato»).
        </p>
      </div>

      {error && (
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            No se confirmó
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
          variante="primario"
          icono={CheckCircle2}
          posicionIcono="izquierda"
          cargando={enviando}
          textoCargando="Confirmando…"
          onClick={confirmar}
        >
          Confirmar que vi la huella
        </Button>
      </div>
    </Modal>
  );
}
