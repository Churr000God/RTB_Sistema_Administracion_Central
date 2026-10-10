import { useCallback, useEffect, useState } from "react";
import { AlertCircle, Loader2 } from "lucide-react";

import { Button } from "./Button";
import { Modal } from "./Modal";
import { formatearHoraMexico } from "../lib/calendario";
import { ErrorApi, apiJson } from "../lib/errorApi";
import {
  ETIQUETA_MOVIMIENTO,
  etiquetaEvidencia,
  muestraEvidencia,
  type EstadoAlta,
  type HuellaEvidencia,
  type MovimientoAlta,
} from "../lib/terminales";

type Props = {
  terminalId: number;
  alta: {
    id: number;
    persona_nombre: string | null;
    employee_no: number;
    estado?: EstadoAlta;
    huella_evidencia?: HuellaEvidencia | null;
    huellas_capturadas?: number;
  };
  onCerrar: () => void;
};

type Estado = "cargando" | "listo" | "error" | "no_existe";

function formatearFecha(fecha: string): string {
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "—";
  return formatearHoraMexico(valor, {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

// Cabecera: la evidencia es la VIGENTE de la alta (su propio campo), nunca la del último movimiento.
function descripcionAlta(alta: Props["alta"]): string {
  const base = `${alta.persona_nombre ?? "—"} · nº ${alta.employee_no}`;
  if (!alta.estado || !muestraEvidencia(alta.estado)) return base;
  const evidencia = etiquetaEvidencia(alta.huella_evidencia, alta.huellas_capturadas);
  return evidencia ? `${base} · ${evidencia}` : base;
}

// Bitácora inmutable del alta (solo lectura). Todo lo que viene del servidor (nombres, detalle) se
// pinta como texto plano.
export function HistorialAltaModal({ terminalId, alta, onCerrar }: Props) {
  const [movimientos, setMovimientos] = useState<MovimientoAlta[]>([]);
  const [estado, setEstado] = useState<Estado>("cargando");

  const cargar = useCallback(() => {
    setEstado("cargando");
    apiJson<MovimientoAlta[]>(`/api/terminales/${terminalId}/usuarios/${alta.id}/movimientos`)
      .then((datos) => {
        setMovimientos(datos);
        setEstado("listo");
      })
      .catch((error) => setEstado(error instanceof ErrorApi && error.status === 404 ? "no_existe" : "error"));
  }, [terminalId, alta.id]);

  useEffect(() => {
    cargar();
  }, [cargar]);

  return (
    <Modal
      titulo="Historial del alta"
      descripcion={descripcionAlta(alta)}
      onCancelar={onCerrar}
    >
      {estado === "cargando" && (
        <p className="boton-con-icono" role="status">
          <Loader2 size={16} className="icono-girando" aria-hidden="true" />
          Cargando historial…
        </p>
      )}
      {estado === "error" && (
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            No se pudo cargar el historial
          </strong>
          <p>Ocurrió un problema al consultar los movimientos.</p>
          <Button onClick={cargar}>Reintentar</Button>
        </div>
      )}
      {estado === "no_existe" && <p>Esta alta ya no existe.</p>}
      {estado === "listo" && movimientos.length === 0 && <p>Esta alta todavía no tiene movimientos.</p>}
      {estado === "listo" && movimientos.length > 0 && (
        <ol className="linea-tiempo">
          {movimientos.map((m) => (
            <li key={m.id} className={m.tipo_movimiento === "error" ? "error" : undefined}>
              <strong>{ETIQUETA_MOVIMIENTO[m.tipo_movimiento] ?? m.tipo_movimiento}</strong>
              <small>
                {formatearFecha(m.creado_en)} · {m.registrado_por_nombre ?? (m.origen === "terminal" ? "Terminal" : "—")}
              </small>
              {m.huella_evidencia === "conteo" && m.huellas_capturadas !== null && m.huellas_capturadas !== undefined && m.huellas_capturadas > 0 && (
                <small>
                  {m.huellas_capturadas} {m.huellas_capturadas === 1 ? "huella registrada" : "huellas registradas"}
                </small>
              )}
              {m.huella_evidencia === "inferida" && <small>Primera marca por huella de esta persona. Sin conteo.</small>}
              {m.huella_evidencia === "manual" && <small>Sin conteo: el aparato no informa cuántas huellas hay.</small>}
              {m.consentimiento && (
                <small>
                  <strong>Consentimiento v{m.consentimiento.version}</strong>
                  {m.consentimiento.cambio_material ? " (cambio material)" : ""}
                </small>
              )}
              {m.detalle && (
                <small>{m.tipo_movimiento === "huella_confirmada_manual" ? `Nota: «${m.detalle}»` : m.detalle}</small>
              )}
            </li>
          ))}
        </ol>
      )}
      <div className="modal__botonera">
        <Button onClick={onCerrar}>Cerrar</Button>
      </div>
    </Modal>
  );
}
