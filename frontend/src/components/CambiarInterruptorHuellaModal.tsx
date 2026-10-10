import { useState } from "react";
import { AlertCircle, AlertTriangle, Fingerprint } from "lucide-react";

import { Button } from "./Button";
import { Modal } from "./Modal";
import { formatearFechaCorta } from "../lib/calendario";
import { ErrorApi, apiJson, codigoDe } from "../lib/errorApi";
import {
  HORA_VENCIMIENTO,
  MAX_NOTA_INTERRUPTOR,
  MIN_NOTA_INTERRUPTOR,
  RUTA_INTERRUPTOR,
  esResultadoCambio,
  esResultadoSinEstado,
  estadoDelError,
  fechaDeAtajo,
  fechaEnRango,
  notaValida,
  sanearNota,
  textoDeError,
  type EstadoInterruptorHuella,
} from "../lib/interruptorHuella";

export type AvisoInterruptor = { tipo: "exito" | "aviso"; texto: string };

type Props = {
  modo: "encender" | "renovar";
  estado: EstadoInterruptorHuella;
  // El cambio se aplicó, o el servidor devolvió el estado actual (409): la pantalla se refresca con él.
  // estado null = el cambio se aplicó pero el servidor no pudo armar el estado: la pantalla lo recarga con el GET.
  onActualizado: (estado: EstadoInterruptorHuella | null, aviso: AvisoInterruptor) => void;
  // Volver a pedir el estado (no_esta_encendido).
  onRecargar: () => void;
  onCerrar: () => void;
};

type Fase = "editando" | "enviando";
type Fallo = { texto: string; codigo: string | null };

const ATAJOS = [7, 14, 30];

// Encender y Renovar comparten formulario: nota (motivo) + fecha de vencimiento. Renovar manda además
// hasta_base (el `hasta` que la pantalla tenía) para que el servidor detecte un estado desactualizado, y
// su nota empieza vacía a propósito. Los errores se traducen por `codigo` a textos fijos locales.
export function CambiarInterruptorHuellaModal({ modo, estado, onActualizado, onRecargar, onCerrar }: Props) {
  const renovar = modo === "renovar";
  const [nota, setNota] = useState("");
  const [fecha, setFecha] = useState(() => fechaDeAtajo(14, estado.fecha_minima, estado.fecha_maxima));
  const [fase, setFase] = useState<Fase>("editando");
  const [notaInvalida, setNotaInvalida] = useState(false);
  const [fechaInvalida, setFechaInvalida] = useState(false);
  const [fallo, setFallo] = useState<Fallo | null>(null);
  const enviando = fase === "enviando";
  const reintentable = fallo?.codigo === "reintentar";

  const venceTexto = fechaEnRango(fecha, estado.fecha_minima, estado.fecha_maxima)
    ? `Vence el ${formatearFechaCorta(fecha)} a las ${HORA_VENCIMIENTO} (hora de México).`
    : `Elige una fecha entre el ${formatearFechaCorta(estado.fecha_minima)} y el ${formatearFechaCorta(estado.fecha_maxima)}.`;

  async function enviar() {
    const notaOk = notaValida(nota);
    const fechaOk = fechaEnRango(fecha, estado.fecha_minima, estado.fecha_maxima);
    setNotaInvalida(!notaOk);
    setFechaInvalida(!fechaOk);
    if (!notaOk || !fechaOk) return;
    setFallo(null);
    setFase("enviando");
    const cuerpo: Record<string, string> = { nota: sanearNota(nota), hasta_fecha: fecha };
    if (renovar && estado.hasta) cuerpo.hasta_base = estado.hasta;
    try {
      const datos = await apiJson<unknown>(`${RUTA_INTERRUPTOR}/${renovar ? "renovar" : "encender"}`, {
        method: "POST",
        body: JSON.stringify(cuerpo),
      });
      if (esResultadoSinEstado(datos)) {
        onActualizado(null, {
          tipo: "exito",
          texto: renovar
            ? "Vencimiento renovado. Tu nota quedó en el historial; recargamos el estado."
            : "Activación por huella encendida. Apágala cuando termine el alta supervisada; recargamos el estado.",
        });
        return;
      }
      if (!esResultadoCambio(datos)) throw new ErrorApi(200, null, null);
      onActualizado(datos.estado, {
        tipo: "exito",
        texto: renovar
          ? `Vencimiento renovado: ahora hasta el ${formatearFechaCorta(datos.estado.hasta_fecha) ?? "—"}. Tu nota quedó en el historial.`
          : `Activación por huella encendida hasta el ${formatearFechaCorta(datos.estado.hasta_fecha) ?? "—"}. Apágala cuando termine el alta supervisada.`,
      });
    } catch (error) {
      const codigo = codigoDe(error);
      const actual = estadoDelError(error);
      if (actual && (codigo === "estado_desactualizado" || codigo === "ya_esta_encendido")) {
        onActualizado(actual, {
          tipo: "aviso",
          texto:
            codigo === "ya_esta_encendido"
              ? "Ya estaba encendido: cargamos el estado actual. Usa Renovar para cambiar el vencimiento."
              : "No se renovó: el estado cambió mientras tenías la ventana abierta. Cargamos el estado actual; revisa si todavía quieres renovar.",
        });
        return;
      }
      setFase("editando");
      setFallo({ texto: textoDeError(error), codigo });
    }
  }

  return (
    <Modal
      titulo={renovar ? "Renovar la activación por huella" : "Encender la activación por huella"}
      descripcion={
        renovar
          ? `Hoy vence el ${formatearFechaCorta(estado.hasta_fecha) ?? "—"}. Escribe una nota nueva (el motivo de la extensión) y el nuevo vencimiento: reemplazan al anterior y quedan en el historial.`
          : "Mientras esté encendida, la primera marca verificada por huella de un usuario recién dado de alta lo activa sin confirmación humana."
      }
      bloqueado={enviando}
      onCancelar={onCerrar}
    >
      <div className="modal__advertencia" role="note">
        <AlertTriangle size={16} aria-hidden="true" />
        <div>
          <strong>Se activarán altas por inferencia.</strong> Es una verificación indirecta, sin conteo de huellas.
          Apágala al terminar el alta supervisada; se apaga sola al vencer.
        </div>
      </div>

      <div className={notaInvalida ? "campo-error" : undefined}>
        <label htmlFor="interruptor-nota">Motivo (obligatorio, mínimo {MIN_NOTA_INTERRUPTOR} caracteres)</label>
        <textarea
          id="interruptor-nota"
          rows={3}
          required
          aria-required="true"
          maxLength={MAX_NOTA_INTERRUPTOR}
          value={nota}
          disabled={enviando}
          aria-invalid={notaInvalida || undefined}
          aria-describedby={`${notaInvalida ? "interruptor-nota-error " : ""}interruptor-nota-contador interruptor-nota-ayuda`}
          placeholder="Ej.: alta supervisada del turno de reparto, con RH presente."
          onChange={(evento) => {
            setNota(evento.target.value);
            if (notaInvalida) setNotaInvalida(false);
          }}
        />
        {notaInvalida && (
          <p className="mensaje-campo" id="interruptor-nota-error">
            <AlertCircle size={14} aria-hidden="true" />
            La nota debe tener entre {MIN_NOTA_INTERRUPTOR} y {MAX_NOTA_INTERRUPTOR} caracteres.
          </p>
        )}
        <div className="modal__contador num" id="interruptor-nota-contador">
          {nota.length} / {MAX_NOTA_INTERRUPTOR} · mínimo {MIN_NOTA_INTERRUPTOR}
        </div>
        <p className="ayuda-campo" id="interruptor-nota-ayuda" style={{ margin: "0.3rem 0 0" }}>
          {renovar && "Al renovar la nota empieza vacía a propósito: explica por qué se extiende, no por qué se encendió. "}
          Queda en el historial con tu nombre. No escribas datos personales de nadie.
        </p>
      </div>

      <div className={fechaInvalida ? "campo-error" : undefined}>
        <label htmlFor="interruptor-fecha">Activo hasta (fecha)</label>
        <input
          id="interruptor-fecha"
          type="date"
          value={fecha}
          min={estado.fecha_minima}
          max={estado.fecha_maxima}
          disabled={enviando}
          aria-invalid={fechaInvalida || undefined}
          aria-describedby="interruptor-fecha-ayuda"
          style={{ maxWidth: "12rem" }}
          onChange={(evento) => {
            setFecha(evento.target.value);
            if (fechaInvalida) setFechaInvalida(false);
          }}
        />
        <p className="ayuda-campo" id="interruptor-fecha-ayuda" style={{ margin: "0.3rem 0 0" }}>
          {venceTexto}
        </p>
      </div>
      <div className="botonera" role="group" aria-label="Atajos de plazo">
        <span className="rango" style={{ alignSelf: "center" }}>
          Atajos:
        </span>
        {ATAJOS.map((dias) => (
          <Button
            key={dias}
            disabled={enviando}
            onClick={() => {
              setFecha(fechaDeAtajo(dias, estado.fecha_minima, estado.fecha_maxima));
              setFechaInvalida(false);
            }}
          >
            {dias} días
          </Button>
        ))}
      </div>

      {fallo && (
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            {renovar ? "No se renovó" : "No se encendió"}
          </strong>
          <p>{fallo.texto}</p>
          {fallo.codigo === "sin_consentimiento_vigente" && (
            <p>
              <a href="/tiempo/terminales/configuracion">Ir a Texto de consentimiento →</a>
            </p>
          )}
          {fallo.codigo === "terminal_no_activa" && (
            <p>
              <a href="/tiempo/terminales">Ver Terminales →</a>
            </p>
          )}
        </div>
      )}

      <div className="modal__botonera">
        <Button disabled={enviando} onClick={onCerrar}>
          Volver
        </Button>
        {fallo?.codigo === "no_esta_encendido" && (
          <Button variante="primario" onClick={onRecargar}>
            Actualizar estado
          </Button>
        )}
        {fallo?.codigo !== "no_esta_encendido" && (
          <Button
            variante="primario"
            icono={Fingerprint}
            posicionIcono="izquierda"
            cargando={enviando}
            textoCargando={renovar ? "Renovando…" : "Encendiendo…"}
            onClick={enviar}
          >
            {reintentable ? "Reintentar" : renovar ? "Renovar la activación" : "Encender la activación"}
          </Button>
        )}
      </div>
    </Modal>
  );
}
