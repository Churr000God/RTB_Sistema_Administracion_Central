import { useId, useState } from "react";
import { ArrowRight, Info, Lock } from "lucide-react";

import { Badge } from "./Badge";

export type MotivoBloqueoCorreccion = "dia_cerrado_pendiente" | "en_tramo_cerrado" | "en_tramo";

// Textos fijos de backend/app/errores.py (MENSAJE_MARCA_EN_TRAMO, el de tramo/día cerrado en
// marcas.py y MENSAJE_DIA_CERRADO_REQUIERE_REVISION). Espejados acá para explicar el bloqueo antes
// de que el usuario intente algo; si backend los cambia hay que actualizarlos juntos.
const CONTENIDO: Record<
  MotivoBloqueoCorreccion,
  { etiqueta: string; variante: "neutra" | "aviso"; mensaje: string }
> = {
  en_tramo: {
    etiqueta: "Ya está en un tramo",
    variante: "neutra",
    mensaje:
      "Esta marca ya forma parte de un tramo: no se puede corregir su hora desde aquí. Revisa el día.",
  },
  en_tramo_cerrado: {
    etiqueta: "Día / tramo cerrado",
    variante: "neutra",
    mensaje: "Este día ya está cerrado: la corrección no se refleja en las horas. Revisa el día.",
  },
  dia_cerrado_pendiente: {
    etiqueta: "Marca tardía · día cerrado",
    variante: "aviso",
    mensaje:
      "Esta marca es de un día ya cerrado: no se corrige ni se resuelve a mano. Revisa el día (o, si el día ya está revisado, descarta la marca tardía).",
  },
};

type Props = {
  motivo: MotivoBloqueoCorreccion;
  hrefDia: string;
};

// "Corregir" bloqueado: sigue visible y en el orden de tab (aria-disabled, no `disabled`) con el
// motivo colgando de aria-describedby; no depende del color (candado + borde punteado + etiqueta).
export function AvisoBloqueoCorreccion({ motivo, hrefDia }: Props) {
  const idMensaje = useId();
  const [abierto, setAbierto] = useState(false);
  // Un motivo nuevo que backend agregue antes que el frontend no debe dejar la pantalla en blanco:
  // cae al aviso de tramo, que igual manda a revisar el día.
  const { etiqueta, variante, mensaje } = CONTENIDO[motivo] ?? CONTENIDO.en_tramo;

  return (
    <div className="aviso-bloqueo">
      <div className="aviso-bloqueo__fila">
        <button
          type="button"
          className="boton-corregir-bloqueado"
          aria-disabled="true"
          aria-describedby={idMensaje}
        >
          <Lock size={14} aria-hidden="true" />
          Corregir
        </button>
        <Badge variante={variante}>{etiqueta}</Badge>
      </div>
      <button
        type="button"
        className="enlace-porque"
        aria-expanded={abierto}
        aria-controls={idMensaje}
        onClick={() => setAbierto((anterior) => !anterior)}
      >
        <Info size={14} aria-hidden="true" />
        ¿Por qué?
      </button>
      <p className="aviso-bloqueo__texto" id={idMensaje} hidden={!abierto}>
        {mensaje}
      </p>
      <div className="aviso-bloqueo__enlaces">
        <a href={hrefDia} className="boton-con-icono">
          Ir a revisar el día
          <ArrowRight size={14} aria-hidden="true" />
        </a>
        {motivo === "dia_cerrado_pendiente" && (
          <a href="/tiempo/excepciones" className="boton-con-icono">
            Ver en excepciones
            <ArrowRight size={14} aria-hidden="true" />
          </a>
        )}
      </div>
    </div>
  );
}
