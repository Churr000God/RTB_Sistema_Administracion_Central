import { useCallback, useEffect, useState } from "react";
import { AlertCircle, CheckCircle2, Info, Loader2 } from "lucide-react";

import { AppShell } from "../layouts/AppShell";
import { Badge } from "../components/Badge";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { DetalleAnomaliaModal } from "../components/DetalleAnomaliaModal";
import { SinAccesoTerminales } from "../components/SinAccesoTerminales";
import { describirHallazgo, esRespuestaAnomalias, type RespuestaAnomalias, type TarjetaAnomalia } from "../lib/anomalias";
import { formatearHoraMexico } from "../lib/calendario";
import { ErrorApi, apiJson } from "../lib/errorApi";
import { useSesion } from "../lib/useSesion";
import type { Terminal } from "../lib/terminales";

type Estado = "cargando" | "listo" | "error" | "sin_acceso" | "sin_terminales";

const FECHA_ISO = /^\d{4}-\d{2}-\d{2}$/;

function terminalDeLaUrl(): string {
  const valor = new URLSearchParams(window.location.search).get("terminal") ?? "";
  return /^[1-9]\d*$/.test(valor) ? valor : "";
}

function VariantePorNivel({ tarjeta }: { tarjeta: TarjetaAnomalia }) {
  if (tarjeta.estado === "sin_hallazgos") return <Badge variante="exito">Sin hallazgos</Badge>;
  if (tarjeta.estado === "no_disponible") return <Badge variante="neutra">No disponible</Badge>;
  if (tarjeta.estado === "error") return <Badge variante="peligro">Error</Badge>;
  if (tarjeta.nivel === "atender") return <Badge variante="peligro">Atender</Badge>;
  if (tarjeta.nivel === "revisar") return <Badge variante="aviso">Revisar</Badge>;
  return <Badge variante="neutra">Informativo</Badge>;
}

export function AnomaliasTerminalesPage() {
  const { sesion, cargando: cargandoSesion } = useSesion();
  const sinAccesoPorSesion = sesion?.puede_ver_terminales === false;

  const [terminales, setTerminales] = useState<Terminal[]>([]);
  const [terminalId, setTerminalId] = useState(terminalDeLaUrl());
  const [desde, setDesde] = useState("");
  const [hasta, setHasta] = useState("");
  const [tablero, setTablero] = useState<RespuestaAnomalias | null>(null);
  const [estado, setEstado] = useState<Estado>("cargando");
  const [detalle, setDetalle] = useState<TarjetaAnomalia | null>(null);

  const errorPeriodo =
    desde && hasta && FECHA_ISO.test(desde) && FECHA_ISO.test(hasta) && hasta < desde
      ? "La fecha final no puede ser anterior a la inicial."
      : null;

  useEffect(() => {
    if (cargandoSesion || sinAccesoPorSesion) return;
    apiJson<Terminal[]>("/api/terminales")
      .then((lista) => {
        if (!Array.isArray(lista)) throw new Error("forma inesperada");
        setTerminales(lista);
        if (lista.length === 0) {
          setEstado("sin_terminales");
          return;
        }
        setTerminalId((actual) => (actual && lista.some((t) => String(t.id) === actual) ? actual : String(lista[0].id)));
      })
      .catch((error) => setEstado(error instanceof ErrorApi && error.status === 403 ? "sin_acceso" : "error"));
  }, [cargandoSesion, sinAccesoPorSesion]);

  const cargar = useCallback(() => {
    // Hasta tener la lista de terminales no se sabe si la de la URL existe ni cuál es la primera.
    if (!terminalId || terminales.length === 0 || errorPeriodo) return;
    setEstado("cargando");
    const params = new URLSearchParams();
    if (FECHA_ISO.test(desde)) params.set("desde", desde);
    if (FECHA_ISO.test(hasta)) params.set("hasta", hasta);
    const consulta = params.toString();
    apiJson<RespuestaAnomalias>(`/api/terminales/${terminalId}/anomalias${consulta ? `?${consulta}` : ""}`)
      .then((datos) => {
        if (!esRespuestaAnomalias(datos)) throw new Error("forma inesperada");
        setTablero(datos);
        setEstado("listo");
      })
      .catch((error) => setEstado(error instanceof ErrorApi && error.status === 403 ? "sin_acceso" : "error"));
  }, [terminalId, terminales, desde, hasta, errorPeriodo]);

  useEffect(() => {
    cargar();
  }, [cargar]);

  const sinAcceso = sinAccesoPorSesion || estado === "sin_acceso";
  const todoLimpio = !!tablero && tablero.categorias.length > 0 && tablero.categorias.every((c) => c.estado === "sin_hallazgos");

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <a href="/tiempo/terminales">Terminales</a> / <strong>Anomalías</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Anomalías de la terminal</h1>
            <p className="subtitulo-pagina">
              Control de abuso y de salud de la terminal, calculado al consultar. Un hallazgo no bloquea nada: es una
              señal para revisar.
            </p>
          </div>
        </div>

        {sinAcceso && <SinAccesoTerminales />}

        {!sinAcceso && estado === "sin_terminales" && (
          <div className="estado-vacio">
            <p>Todavía no hay terminales dadas de alta.</p>
          </div>
        )}

        {!sinAcceso && estado !== "sin_terminales" && terminales.length > 0 && (
          <div className="barra-filtros">
            <div>
              <label htmlFor="anomalias-terminal">Terminal</label>
              <select id="anomalias-terminal" value={terminalId} onChange={(evento) => setTerminalId(evento.target.value)}>
                {terminales.map((t) => (
                  <option key={t.id} value={t.id}>
                    {t.nombre}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <label htmlFor="anomalias-desde">Periodo desde</label>
              <input id="anomalias-desde" type="date" value={desde} onChange={(evento) => setDesde(evento.target.value)} />
            </div>
            <div>
              <label htmlFor="anomalias-hasta">Periodo hasta</label>
              <input id="anomalias-hasta" type="date" value={hasta} onChange={(evento) => setHasta(evento.target.value)} />
            </div>
          </div>
        )}
        {errorPeriodo && (
          <p className="mensaje-campo">
            <AlertCircle size={14} aria-hidden="true" />
            {errorPeriodo}
          </p>
        )}

        {!sinAcceso && estado === "cargando" && (
          <p className="boton-con-icono" role="status">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Calculando anomalías…
          </p>
        )}

        {!sinAcceso && estado === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo calcular el tablero
            </strong>
            <p>Ocurrió un problema al consultar las anomalías.</p>
            <Button onClick={cargar}>Reintentar</Button>
          </div>
        )}

        {!sinAcceso && estado === "listo" && tablero && (
          <>
            {todoLimpio && (
              <div className="banner-aviso banner-aviso--info" role="status">
                <CheckCircle2 size={16} aria-hidden="true" />
                <div>
                  <strong>Sin hallazgos en el periodo.</strong> Las {tablero.categorias.length} revisiones se hicieron y
                  ninguna encontró nada que atender.
                </div>
              </div>
            )}
            <p className="rango">
              Calculado a las{" "}
              {formatearHoraMexico(new Date(tablero.generado_en), { hour: "2-digit", minute: "2-digit" })} (el
              servidor lo conserva 45 s).
            </p>
            <div className="rejilla-anomalias">
              {tablero.categorias.map((tarjeta) => (
                <Card key={tarjeta.clave} className="anomalia">
                  <header>
                    <h3>
                      {tarjeta.numero} · {tarjeta.titulo}
                    </h3>
                    <VariantePorNivel tarjeta={tarjeta} />
                  </header>
                  {tarjeta.estado === "con_hallazgos" && <span className="cifra num">{tarjeta.total}</span>}
                  {tarjeta.estado === "con_hallazgos" && (
                    <ul>
                      {tarjeta.ejemplos.map((ejemplo, indice) => (
                        <li key={indice}>{describirHallazgo(tarjeta.clave, ejemplo)}</li>
                      ))}
                    </ul>
                  )}
                  {tarjeta.nota && (tarjeta.estado === "con_hallazgos" || (tarjeta.clave === "interruptor_huella" && tarjeta.estado === "sin_hallazgos")) && (
                    <p className="ayuda-campo" style={{ margin: "0.5rem 0 0" }}>
                      <Info size={14} aria-hidden="true" /> {tarjeta.nota}
                    </p>
                  )}
                  {tarjeta.estado === "sin_hallazgos" && (
                    <ul>
                      <li>Nada que mostrar en este periodo.</li>
                    </ul>
                  )}
                  {tarjeta.estado === "no_disponible" && (
                    <ul>
                      <li>
                        {tarjeta.motivo === "sin_permiso"
                          ? "Esta revisión requiere el permiso de lectura de marcas (marca_lectura), que tu cuenta no tiene."
                          : "Esta revisión aún no está disponible en el servidor."}
                      </li>
                    </ul>
                  )}
                  {tarjeta.estado === "error" && (
                    <p role="alert" className="error-terminal">
                      No se pudo calcular esta revisión. Las demás siguen disponibles.
                    </p>
                  )}
                  {tarjeta.estado === "con_hallazgos" && tarjeta.hay_mas && (
                    <Button onClick={() => setDetalle(tarjeta)}>{`Ver todos (${tarjeta.total})`}</Button>
                  )}
                  {tarjeta.clave === "interruptor_huella" && tarjeta.estado === "con_hallazgos" && (
                    <a href="/tiempo/terminales/configuracion/activacion-por-huella">Ir a Configuración → Activación por huella →</a>
                  )}
                  {tarjeta.clave === "reconsentimientos_pendientes" && tarjeta.estado === "con_hallazgos" && (
                    <a href={`/tiempo/terminales/${terminalId}/usuarios`}>Ver y registrar →</a>
                  )}
                </Card>
              ))}
            </div>
          </>
        )}

        {detalle && (
          <DetalleAnomaliaModal
            terminalId={Number(terminalId)}
            clave={detalle.clave}
            titulo={detalle.titulo}
            desde={FECHA_ISO.test(desde) ? desde : ""}
            hasta={FECHA_ISO.test(hasta) ? hasta : ""}
            onCerrar={() => setDetalle(null)}
          />
        )}
      </div>
    </AppShell>
  );
}
