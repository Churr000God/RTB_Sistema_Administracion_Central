import { useCallback, useEffect, useMemo, useState } from "react";
import { AlertCircle, ArrowRight, Fingerprint, Loader2 } from "lucide-react";

import { AppShell } from "../layouts/AppShell";
import { Badge } from "../components/Badge";
import { Button } from "../components/Button";
import { SinAccesoTerminales } from "../components/SinAccesoTerminales";
import { ErrorApi, apiJson } from "../lib/errorApi";
import { useSesion } from "../lib/useSesion";
import {
  ETIQUETA_CONTACTO,
  descripcionUltimoContacto,
  formatearDesfase,
  type EstadoContacto,
  type Terminal,
} from "../lib/terminales";

const REFRESCO_MS = 60_000;

type Estado = "cargando" | "listo" | "error" | "sin_acceso";

const PUNTO_CONTACTO: Record<EstadoContacto, string> = {
  en_linea: "punto punto--exito",
  sin_contacto: "punto punto--aviso",
  nunca: "punto",
  inactiva: "punto",
};

export function TerminalesPage() {
  const { sesion, cargando: cargandoSesion } = useSesion();
  const sinAccesoPorSesion = sesion?.puede_ver_terminales === false;
  const [terminales, setTerminales] = useState<Terminal[]>([]);
  const [estado, setEstado] = useState<Estado>("cargando");

  const cargar = useCallback((silencioso: boolean) => {
    if (!silencioso) setEstado("cargando");
    apiJson<Terminal[]>("/api/terminales")
      .then((datos) => {
        if (!Array.isArray(datos)) throw new Error("forma inesperada");
        setTerminales(datos);
        setEstado("listo");
      })
      .catch((error) => {
        // Un refresco silencioso que falla no tira una lista ya visible.
        if (silencioso) return;
        setEstado(error instanceof ErrorApi && error.status === 403 ? "sin_acceso" : "error");
      });
  }, []);

  useEffect(() => {
    if (cargandoSesion || sinAccesoPorSesion) return;
    cargar(false);
    const intervalo = setInterval(() => cargar(true), REFRESCO_MS);
    return () => clearInterval(intervalo);
  }, [cargandoSesion, sinAccesoPorSesion, cargar]);

  const resumen = useMemo(
    () => ({
      enLinea: terminales.filter((t) => t.estado_contacto === "en_linea").length,
      sinContacto: terminales.filter((t) => t.estado_contacto === "sin_contacto").length,
      conPendientes: terminales.filter((t) => t.marcas_pendientes > 0).length,
    }),
    [terminales],
  );

  const sinAcceso = sinAccesoPorSesion || estado === "sin_acceso";

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <strong>Terminales</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Terminales</h1>
            <p className="subtitulo-pagina">
              Aparatos de checado y el estado de su puente. Sólo lectura: desde aquí entras a los usuarios de
              cada terminal.
            </p>
          </div>
        </div>

        {sinAcceso && <SinAccesoTerminales />}

        {!sinAcceso && estado === "cargando" && (
          <p className="boton-con-icono" role="status">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando terminales…
          </p>
        )}

        {!sinAcceso && estado === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar las terminales
            </strong>
            <p>Ocurrió un problema al consultar las terminales.</p>
            <Button onClick={() => cargar(false)}>Reintentar</Button>
          </div>
        )}

        {!sinAcceso && estado === "listo" && terminales.length === 0 && (
          <div className="estado-vacio">
            <Fingerprint size={40} aria-hidden="true" />
            <p>
              <strong>Todavía no hay terminales dadas de alta.</strong>
              <br />
              El alta de una terminal es un procedimiento de Sistemas (serie del aparato y llave del puente), no
              se hace desde esta pantalla.
            </p>
          </div>
        )}

        {!sinAcceso && estado === "listo" && terminales.length > 0 && (
          <>
            <div className="banda-metricas">
              <div className="metrica">
                <span className="etiqueta-metrica">
                  <span className="punto punto--exito" aria-hidden="true" />
                  En línea
                </span>
                <strong>{resumen.enLinea}</strong>
              </div>
              <div className="metrica">
                <span className="etiqueta-metrica">
                  <span className="punto punto--aviso" aria-hidden="true" />
                  Sin contacto
                </span>
                <strong>{resumen.sinContacto}</strong>
              </div>
              <div className="metrica">
                <span className="etiqueta-metrica">
                  <span className="punto punto--peligro" aria-hidden="true" />
                  Con marcas pendientes
                </span>
                <strong>{resumen.conPendientes}</strong>
              </div>
            </div>
            <div className="tabla-desplazable">
              <table>
                <thead>
                  <tr>
                    <th>Terminal</th>
                    <th>Serie</th>
                    <th>Contacto</th>
                    <th>Última comunicación</th>
                    <th>Terminal alcanzable</th>
                    <th>Desfase del reloj</th>
                    <th>Versión del puente</th>
                    <th>Marcas pendientes</th>
                    <th>Acción</th>
                  </tr>
                </thead>
                <tbody>
                  {terminales.map((terminal) => (
                    <tr key={terminal.id}>
                      <td>
                        <strong>{terminal.nombre}</strong>
                      </td>
                      <td className="num">{terminal.serie}</td>
                      <td>
                        <span className="contacto">
                          <span className={PUNTO_CONTACTO[terminal.estado_contacto]} aria-hidden="true" />
                          {ETIQUETA_CONTACTO[terminal.estado_contacto]}
                        </span>
                        {terminal.estado_contacto === "sin_contacto" && (
                          <div className="ayuda-campo">las altas siguen esperando</div>
                        )}
                      </td>
                      <td className="num">{descripcionUltimoContacto(terminal.segundos_sin_contacto)}</td>
                      <td>
                        {terminal.terminal_alcanzable === null ? (
                          "—"
                        ) : terminal.terminal_alcanzable ? (
                          <Badge variante="exito">Sí</Badge>
                        ) : (
                          <Badge variante="aviso">No se ve</Badge>
                        )}
                      </td>
                      <td className="num">{formatearDesfase(terminal.reloj_desfase_seg)}</td>
                      <td className="num">{terminal.version_pi ?? "—"}</td>
                      <td className="num">
                        {terminal.marcas_pendientes > 0 ? (
                          <Badge variante="peligro">{terminal.marcas_pendientes}</Badge>
                        ) : (
                          terminal.marcas_pendientes
                        )}
                      </td>
                      <td>
                        <a href={`/tiempo/terminales/${terminal.id}/usuarios`} className="boton-con-icono">
                          Usuarios
                          <ArrowRight size={14} aria-hidden="true" />
                        </a>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="pie-tabla">
              {terminales.length} {terminales.length === 1 ? "terminal" : "terminales"} · se refresca solo cada 60 s
            </p>
          </>
        )}
      </div>
    </AppShell>
  );
}
