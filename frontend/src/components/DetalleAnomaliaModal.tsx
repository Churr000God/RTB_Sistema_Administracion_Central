import { useCallback, useEffect, useState } from "react";
import { AlertCircle, Loader2 } from "lucide-react";

import { Button } from "./Button";
import { Modal } from "./Modal";
import { describirHallazgo, type DetalleAnomalia } from "../lib/anomalias";
import { ErrorApi, apiJson } from "../lib/errorApi";

const PAGINA = 50;

type Props = {
  terminalId: number;
  clave: string;
  titulo: string;
  desde: string;
  hasta: string;
  onCerrar: () => void;
};

type Estado = "cargando" | "listo" | "sin_permiso" | "error";

// «Ver todos» de una categoría del tablero: lista paginada de a 50 (texto plano, sin identificadores).
export function DetalleAnomaliaModal({ terminalId, clave, titulo, desde, hasta, onCerrar }: Props) {
  const [items, setItems] = useState<Record<string, unknown>[]>([]);
  const [total, setTotal] = useState(0);
  const [estado, setEstado] = useState<Estado>("cargando");
  const [cargandoMas, setCargandoMas] = useState(false);

  const cargar = useCallback(
    (desplazamiento: number) => {
      if (desplazamiento === 0) setEstado("cargando");
      else setCargandoMas(true);
      const params = new URLSearchParams();
      if (desde) params.set("desde", desde);
      if (hasta) params.set("hasta", hasta);
      params.set("limite", String(PAGINA));
      params.set("desplazamiento", String(desplazamiento));
      apiJson<DetalleAnomalia>(`/api/terminales/${terminalId}/anomalias/${clave}?${params.toString()}`)
        .then((datos) => {
          if (!Array.isArray(datos.items)) throw new Error("forma inesperada");
          setItems((anteriores) => (desplazamiento === 0 ? datos.items : [...anteriores, ...datos.items]));
          setTotal(datos.total);
          setEstado("listo");
        })
        .catch((error) => setEstado(error instanceof ErrorApi && error.status === 403 ? "sin_permiso" : "error"))
        .finally(() => setCargandoMas(false));
    },
    [terminalId, clave, desde, hasta],
  );

  useEffect(() => {
    cargar(0);
  }, [cargar]);

  return (
    <Modal titulo={titulo} descripcion={estado === "listo" ? `${total} hallazgos en el periodo` : undefined} onCancelar={onCerrar}>
      {estado === "cargando" && (
        <p className="boton-con-icono" role="status">
          <Loader2 size={16} className="icono-girando" aria-hidden="true" />
          Cargando el detalle…
        </p>
      )}
      {estado === "sin_permiso" && (
        <p>Esta revisión requiere el permiso de lectura de marcas (marca_lectura), que tu cuenta no tiene.</p>
      )}
      {estado === "error" && (
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            No se pudo cargar el detalle
          </strong>
          <p>Ocurrió un problema al consultar los hallazgos.</p>
          <Button onClick={() => cargar(items.length > 0 ? items.length : 0)}>Reintentar</Button>
        </div>
      )}
      {estado === "listo" && (
        <>
          <ul style={{ margin: 0, paddingLeft: "1.1rem", fontSize: "0.88rem", lineHeight: 1.6 }}>
            {items.map((item, indice) => (
              <li key={indice}>{describirHallazgo(clave, item)}</li>
            ))}
          </ul>
          {items.length < total && (
            <Button cargando={cargandoMas} textoCargando="Cargando…" onClick={() => cargar(items.length)}>
              Cargar más
            </Button>
          )}
        </>
      )}
      <div className="modal__botonera">
        <Button onClick={onCerrar}>Cerrar</Button>
      </div>
    </Modal>
  );
}
