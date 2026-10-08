import { useEffect, useId, useRef, useState } from "react";
import { AlertCircle, AlertTriangle, CheckCircle2, Info, Trash2 } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { formatearFechaCorta, formatearHoraMexico } from "../lib/calendario";
import { Button } from "./Button";
import { Badge } from "./Badge";

const MAX_MOTIVO = 500;

export type ExcepcionADescartar = {
  id: number;
  persona_nombre: string | null;
  momento_dispositivo: string | null;
  dia_de_la_marca_fecha?: string | null;
  dia_de_la_marca_estado?: "abierto" | "bloqueado" | "cerrado" | "revisado" | null;
};

type Props = {
  excepcion: ExcepcionADescartar;
  // refrescar=true cuando la lista cambió (descartó, ya estaba descartada o hubo un 409).
  onCerrar: (refrescar: boolean) => void;
};

type Fase = "editando" | "enviando" | "descartada" | "ya_descartada";

// Sólo el 409 (conflictos de negocio: día no revisado, no descartable, ya descartada) muestra el
// detail del servidor — son mensajes fijos de backend/app/errores.py. Cualquier otro status usa
// siempre este respaldo: un detail inesperado (errores internos, ids) no debe llegar a pantalla.
const MENSAJE_GENERICO = "No se pudo completar. Inténtalo de nuevo.";
const MENSAJE_CONFLICTO_RESPALDO =
  "La excepción cambió de estado. Actualiza la lista para ver su situación actual.";
const MENSAJE_RESPALDO: Record<number, string> = {
  403: "No tienes permiso para esta acción.",
  422: "El motivo es obligatorio.",
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

// Primer modal del proyecto: <dialog> nativo con showModal() (foco atrapado, Esc, ::backdrop).
// Descartar es irreversible y queda auditado, por eso pide motivo y confirma con un botón propio.
export function DescartarMarcaTardiaModal({ excepcion, onCerrar }: Props) {
  const dialogoRef = useRef<HTMLDialogElement>(null);
  const idTitulo = useId();
  const idContexto = useId();
  const idError = useId();
  const [motivo, setMotivo] = useState("");
  const [fase, setFase] = useState<Fase>("editando");
  const [errorCampo, setErrorCampo] = useState(false);
  const [errorServidor, setErrorServidor] = useState<{ texto: string; conflicto: boolean } | null>(null);

  useEffect(() => {
    const dialogo = dialogoRef.current;
    if (dialogo && !dialogo.open) dialogo.showModal();
  }, []);

  // Cierra el <dialog> nativo antes de avisar al padre: así el navegador devuelve el foco al botón
  // que lo abrió (el padre desmonta el componente enseguida).
  function cerrar(refrescar: boolean) {
    dialogoRef.current?.close();
    onCerrar(refrescar);
  }

  const enviando = fase === "enviando";
  const terminado = fase === "descartada" || fase === "ya_descartada";
  const fecha = formatearFechaCorta(excepcion.dia_de_la_marca_fecha);

  async function descartar() {
    const texto = motivo.trim();
    if (texto.length < 1 || texto.length > MAX_MOTIVO) {
      setErrorCampo(true);
      return;
    }
    setErrorCampo(false);
    setErrorServidor(null);
    setFase("enviando");
    try {
      const respuesta = await apiFetch(`/api/excepciones/${excepcion.id}/descartar`, {
        method: "POST",
        body: JSON.stringify({ motivo: texto }),
      });
      if (respuesta.ok) {
        const cuerpo = await respuesta.json();
        setFase(cuerpo?.resultado === "ya_descartada" ? "ya_descartada" : "descartada");
        return;
      }
      const detalle = await leerDetalle(respuesta);
      setErrorServidor({
        texto:
          respuesta.status === 409
            ? (detalle ?? MENSAJE_CONFLICTO_RESPALDO)
            : (MENSAJE_RESPALDO[respuesta.status] ?? MENSAJE_GENERICO),
        conflicto: respuesta.status === 409,
      });
    } catch {
      setErrorServidor({ texto: "No se pudo completar. Revisa tu conexión e inténtalo de nuevo.", conflicto: false });
    }
    setFase("editando");
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
            {fase === "descartada" ? (
              <>
                <CheckCircle2 size={22} aria-hidden="true" /> Marca descartada
              </>
            ) : (
              <>
                <Info size={22} aria-hidden="true" /> Ya estaba descartada
              </>
            )}
          </h2>
          <p className="modal__contexto" id={idContexto}>
            {fase === "descartada"
              ? `La marca tardía de ${excepcion.persona_nombre ?? "la persona"} quedó descartada y registrada con tu nombre y el motivo indicado. Ya no aparece en las excepciones pendientes.`
              : "Esta marca ya había sido descartada antes: no se hizo ningún cambio ni se escribió otro registro. La lista se actualizará."}
          </p>
          <div className="modal__botonera">
            <Button variante="primario" onClick={() => cerrar(true)}>
              Cerrar
            </Button>
          </div>
        </div>
      ) : (
        <>
          <h2 id={idTitulo}>Descartar marca tardía</h2>
          <p className="modal__contexto" id={idContexto}>
            Marca de <strong>{excepcion.persona_nombre ?? "—"}</strong> ·{" "}
            {formatearMarca(excepcion.momento_dispositivo)}
            {fecha && (
              <>
                {" "}
                · día <strong>{fecha}</strong>
              </>
            )}{" "}
            {excepcion.dia_de_la_marca_estado === "revisado" && <Badge variante="exito">Revisado</Badge>}
          </p>
          <div className="modal__advertencia" role="note">
            <AlertTriangle size={16} aria-hidden="true" />
            <div>
              <strong>Esta acción es irreversible.</strong> La marca tardía quedará descartada y no podrá
              recuperarse. Queda registrado <strong>quién</strong> la descartó y <strong>por qué</strong> (el
              motivo que escribas aquí). No cambia las horas del día ya revisado.
            </div>
          </div>
          <div className={errorCampo ? "campo-error" : undefined}>
            <label htmlFor={`${idTitulo}-motivo`}>Motivo del descarte (obligatorio)</label>
            <textarea
              id={`${idTitulo}-motivo`}
              rows={4}
              maxLength={MAX_MOTIVO}
              value={motivo}
              aria-invalid={errorCampo || undefined}
              aria-describedby={errorCampo ? idError : undefined}
              placeholder="Ej.: la persona confirmó que fue un registro accidental después de su salida."
              disabled={enviando}
              onChange={(evento) => {
                setMotivo(evento.target.value);
                if (errorCampo) setErrorCampo(false);
              }}
            />
            {errorCampo && (
              <p className="mensaje-campo" id={idError}>
                <AlertCircle size={14} aria-hidden="true" />
                Escribe un motivo (entre 1 y 500 caracteres).
              </p>
            )}
            <div className="modal__contador num">
              {motivo.length} / {MAX_MOTIVO}
            </div>
          </div>
          {errorServidor && (
            <div className="tarjeta-error" role="alert">
              <strong>
                <AlertCircle size={16} aria-hidden="true" />
                No se descartó la marca
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
                Descartar definitivamente
              </Button>
            )}
          </div>
        </>
      )}
    </dialog>
  );
}
