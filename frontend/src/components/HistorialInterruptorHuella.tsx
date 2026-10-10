import { useCallback, useEffect, useState } from "react";
import { AlertCircle, AlertTriangle, Loader2, Lock } from "lucide-react";

import { Badge } from "./Badge";
import { Button } from "./Button";
import { Card } from "./Card";
import { formatearHoraMexico } from "../lib/calendario";
import { ErrorApi, apiJson } from "../lib/errorApi";
import { RUTA_INTERRUPTOR, describirCambio, type ItemHistorialInterruptor } from "../lib/interruptorHuella";

type Props = {
  // false = el caller sólo tiene terminal_usuario_lectura: el servidor respondería 403, así que ni se pide.
  puedeVer: boolean;
  // Cambia cada vez que la pantalla aplica un cambio, para volver a pedir el historial.
  version: number;
};

type Estado = "cargando" | "listo" | "error" | "sin_permiso";

function formatearFecha(fecha: string): string {
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "—";
  return formatearHoraMexico(valor, { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
}

// Historial de cambios del interruptor (sólo terminal_usuario_edicion / terminal_config_edicion). Notas y
// nombres son texto plano; un cambio con via_funcion=false se marca como hecho fuera de la función.
export function HistorialInterruptorHuella({ puedeVer, version }: Props) {
  const [items, setItems] = useState<ItemHistorialInterruptor[]>([]);
  const [estado, setEstado] = useState<Estado>("cargando");

  const cargar = useCallback(() => {
    setEstado("cargando");
    apiJson<{ items: ItemHistorialInterruptor[] }>(`${RUTA_INTERRUPTOR}/historial?limite=50`)
      .then((datos) => {
        if (!datos || !Array.isArray(datos.items)) throw new Error("forma inesperada");
        setItems(datos.items);
        setEstado("listo");
      })
      .catch((error) => setEstado(error instanceof ErrorApi && error.status === 403 ? "sin_permiso" : "error"));
  }, []);

  useEffect(() => {
    if (puedeVer) cargar();
  }, [puedeVer, version, cargar]);

  if (!puedeVer || estado === "sin_permiso") {
    return (
      <Card style={{ marginTop: "1.25rem" }}>
        <h3>Historial de cambios</h3>
        <div className="estado-vacio" style={{ padding: "1rem 0" }}>
          <Lock size={28} aria-hidden="true" />
          <p>
            El historial no está disponible con tu permiso. Para verlo hace falta{" "}
            <span className="chip-permiso">terminal_usuario_edicion</span> o{" "}
            <span className="chip-permiso">terminal_config_edicion</span>.
          </p>
        </div>
      </Card>
    );
  }

  return (
    <Card style={{ marginTop: "1.25rem" }}>
      <h3>Historial de cambios</h3>
      <p className="ayuda-campo" style={{ margin: "0 0 0.6rem" }}>
        Cada encendido, renovación y apagado queda con quién, cuándo y la nota. No se puede editar ni borrar. Un cambio
        marcado «Fuera de la función» se hizo sin pasar por esta pantalla.
      </p>
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
          <p>Ocurrió un problema al consultar los cambios. El estado de arriba sigue siendo válido.</p>
          <Button onClick={cargar}>Reintentar</Button>
        </div>
      )}
      {estado === "listo" && items.length === 0 && (
        <div className="estado-vacio" style={{ padding: "1.5rem 0" }}>
          <p>Todavía no hay cambios registrados. El ajuste está en su valor de fábrica (apagado).</p>
        </div>
      )}
      {estado === "listo" && items.length > 0 && (
        <>
          <div className="tabla-desplazable">
            <table>
              <thead>
                <tr>
                  <th>Cuándo</th>
                  <th>Cambio</th>
                  <th>Nota</th>
                  <th>Quién</th>
                  <th>Origen</th>
                </tr>
              </thead>
              <tbody>
                {items.map((item) => (
                  <tr key={item.id}>
                    <td className="num">{formatearFecha(item.creado_en)}</td>
                    <td>{describirCambio(item)}</td>
                    <td>{item.nota ?? "—"}</td>
                    <td>{item.autor_nombre ?? "Sin autor"}</td>
                    <td>
                      {item.via_funcion ? (
                        <Badge variante="neutra">Desde la pantalla</Badge>
                      ) : (
                        <Badge variante="peligro" className="estado-alta">
                          <AlertTriangle size={12} aria-hidden="true" />
                          Fuera de la función
                        </Badge>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="rango" style={{ margin: "0.5rem 0 0" }}>
            Se muestran los últimos {items.length} cambios.
          </p>
        </>
      )}
    </Card>
  );
}
