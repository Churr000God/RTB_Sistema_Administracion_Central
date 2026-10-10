import { useState } from "react";
import { AlertCircle, AlertTriangle, X } from "lucide-react";

import { Button } from "./Button";
import { Modal } from "./Modal";
import { ErrorApi, apiJson, codigoDe } from "../lib/errorApi";
import {
  MAX_NOTA_INTERRUPTOR,
  RUTA_INTERRUPTOR,
  esResultadoCambio,
  sanearNota,
  textoDeError,
  type EstadoInterruptorHuella,
} from "../lib/interruptorHuella";
import type { AvisoInterruptor } from "./CambiarInterruptorHuellaModal";

type Props = {
  onActualizado: (estado: EstadoInterruptorHuella, aviso: AvisoInterruptor) => void;
  onCerrar: () => void;
};

// Apagar siempre se puede y no pide nota (si viene, queda en el historial). Si ya estaba apagado el
// servidor responde «sin_cambio» y la pantalla lo dice.
export function ApagarInterruptorHuellaModal({ onActualizado, onCerrar }: Props) {
  const [nota, setNota] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [fallo, setFallo] = useState<{ texto: string; codigo: string | null } | null>(null);

  async function apagar() {
    const limpia = sanearNota(nota);
    setFallo(null);
    setEnviando(true);
    try {
      const datos = await apiJson<unknown>(`${RUTA_INTERRUPTOR}/apagar`, {
        method: "POST",
        body: JSON.stringify(limpia ? { nota: limpia } : {}),
      });
      if (!esResultadoCambio(datos)) throw new ErrorApi(200, null, null);
      onActualizado(
        datos.estado,
        datos.resultado === "sin_cambio"
          ? { tipo: "aviso", texto: "Ya estaba apagado: no hubo cambios. Cargamos el estado actual." }
          : {
              tipo: "exito",
              texto: "Activación por huella apagada. Las altas nuevas vuelven a necesitar la confirmación de una persona con «Confirmar huella».",
            },
      );
    } catch (error) {
      setEnviando(false);
      setFallo({ texto: textoDeError(error), codigo: codigoDe(error) });
    }
  }

  return (
    <Modal
      titulo="Apagar la activación por huella"
      descripcion="Las altas nuevas volverán a necesitar que una persona pulse «Confirmar huella». No cambia a las altas que ya están activas."
      bloqueado={enviando}
      onCancelar={onCerrar}
    >
      <div className="modal__advertencia" role="note">
        <AlertTriangle size={16} aria-hidden="true" />
        <div>
          <strong>Las altas que están en «Esperando huella» dejan de activarse solas.</strong> Si alguna no se confirma
          antes de caducar, se dará de baja y se borrará del aparato. Confirma o enrola esas altas antes de apagar.
          Podrás volver a encenderla con una nota y un vencimiento nuevos (el conteo de altas activadas empieza de cero).
        </div>
      </div>
      <div>
        <label htmlFor="interruptor-apagar-nota">Nota (opcional, hasta {MAX_NOTA_INTERRUPTOR} caracteres)</label>
        <textarea
          id="interruptor-apagar-nota"
          rows={2}
          maxLength={MAX_NOTA_INTERRUPTOR}
          value={nota}
          disabled={enviando}
          aria-describedby="interruptor-apagar-contador interruptor-apagar-ayuda"
          placeholder="Ej.: terminó el alta supervisada."
          onChange={(evento) => setNota(evento.target.value)}
        />
        <div className="modal__contador num" id="interruptor-apagar-contador">
          {nota.length} / {MAX_NOTA_INTERRUPTOR}
        </div>
        <p className="ayuda-campo" id="interruptor-apagar-ayuda" style={{ margin: "0.3rem 0 0" }}>
          Apagar siempre se puede y no necesita nota; si la escribes, queda en el historial junto a tu nombre y la hora.
        </p>
      </div>
      {fallo && (
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            No se apagó
          </strong>
          <p>{fallo.texto}</p>
        </div>
      )}
      <div className="modal__botonera">
        <Button disabled={enviando} onClick={onCerrar}>
          Volver
        </Button>
        <Button
          className="boton-peligro"
          icono={X}
          posicionIcono="izquierda"
          cargando={enviando}
          textoCargando="Apagando…"
          onClick={apagar}
        >
          {fallo?.codigo === "reintentar" ? "Reintentar" : "Apagar la activación"}
        </Button>
      </div>
    </Modal>
  );
}
