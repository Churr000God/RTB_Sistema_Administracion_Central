import { useEffect, useMemo, useState } from "react";
import {
  AlertCircle,
  CalendarCheck2,
  Landmark,
  Loader2,
  PlayCircle,
  ShieldCheck,
  type LucideIcon,
} from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { aFechaISO } from "../lib/calendario";
import { AppShell } from "../layouts/AppShell";
import { Badge } from "../components/Badge";
import { Button } from "../components/Button";

type EstadoCorrida = "en_progreso" | "exitosa" | "fallida";

type CorridaBatch = {
  id: number;
  tipo_batch: string;
  fecha: string;
  estado: EstadoCorrida;
  intentos: number;
  iniciado_en: string;
  terminado_en: string | null;
  detalle: string | null;
};

type EstadoCarga = "cargando" | "listo" | "error";

// Catálogo de botones de disparo manual. SCJ-PRO-14 (de_confianza) es el único construido hoy;
// SCJ-PRO-12 (cierre_dia) y SCJ-PRO-13 (corte_quincenal) reusan la misma corrida_batch/panel en
// Fase 4 — agregar su fila acá cuando el botón exista, la tabla de abajo ya lista cualquier
// tipo_batch presente en la respuesta sin cambios.
// `ruta` es el slug con guiones del endpoint (POST /api/corridas-batch/de-confianza) —
// distinto de `codigo`, que es el valor real de tipo_batch en la base (con guion bajo).
const TIPOS_BATCH_DISPARABLES: {
  codigo: string;
  ruta: string;
  etiqueta: string;
  descripcion: string;
  icono: LucideIcon;
  fechaInicial: "hoy" | "ayer";
}[] = [
  {
    codigo: "de_confianza",
    ruta: "de-confianza",
    etiqueta: "Jornada de confianza",
    descripcion: "Cierra el día de quienes tienen jornada de confianza — sin marca que validar.",
    icono: ShieldCheck,
    fechaInicial: "hoy",
  },
  {
    codigo: "cierre_dia",
    ruta: "cierre-dia",
    etiqueta: "Cierre de día",
    descripcion: "Calcula horas trabajadas y detecta faltas del día elegido, por persona.",
    icono: CalendarCheck2,
    fechaInicial: "ayer",
  },
  {
    codigo: "corte_quincenal",
    ruta: "corte-quincenal",
    etiqueta: "Corte quincenal",
    descripcion: "Aplica el saldo del periodo al banco de horas de cada persona.",
    icono: Landmark,
    fechaInicial: "hoy",
  },
];

function fechaHoyISO(): string {
  return aFechaISO(new Date());
}

function fechaAyerISO(): string {
  const ayer = new Date();
  ayer.setDate(ayer.getDate() - 1);
  return aFechaISO(ayer);
}

function fechasIniciales(): Record<string, string> {
  return Object.fromEntries(
    TIPOS_BATCH_DISPARABLES.map(({ codigo, fechaInicial }) => [
      codigo,
      fechaInicial === "ayer" ? fechaAyerISO() : fechaHoyISO(),
    ]),
  );
}

const ETIQUETA_TIPO_BATCH: Record<string, string> = {
  de_confianza: "Jornada de confianza",
  cierre_dia: "Cierre de día",
  corte_quincenal: "Corte quincenal",
};

const VARIANTE_ESTADO: Record<EstadoCorrida, "aviso" | "exito" | "peligro"> = {
  en_progreso: "aviso",
  exitosa: "exito",
  fallida: "peligro",
};

const ETIQUETA_ESTADO: Record<EstadoCorrida, string> = {
  en_progreso: "En progreso",
  exitosa: "Exitosa",
  fallida: "Fallida",
};

async function mensajeDeError(respuesta: Response, generico: string): Promise<string> {
  try {
    const cuerpo = await respuesta.json();
    if (typeof cuerpo?.detail === "string") return cuerpo.detail;
  } catch {
    // cuerpo no era JSON legible — cae al genérico
  }
  return generico;
}

function formatearFechaHora(fecha: string | null): string {
  if (!fecha) return "—";
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleString("es-MX", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function PanelCorridasBatchPage() {
  const [corridas, setCorridas] = useState<CorridaBatch[]>([]);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [disparando, setDisparando] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [fechas, setFechas] = useState<Record<string, string>>(fechasIniciales);

  function cargar() {
    setEstadoCarga("cargando");
    apiFetch("/api/corridas-batch")
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datos: CorridaBatch[]) => {
        setCorridas(datos);
        setEstadoCarga("listo");
      })
      .catch(() => setEstadoCarga("error"));
  }

  useEffect(() => {
    cargar();
  }, []);

  async function dispararBatch(codigo: string, ruta: string) {
    setError(null);
    setDisparando(codigo);
    try {
      const respuesta = await apiFetch(`/api/corridas-batch/${ruta}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ fecha: fechas[codigo] }),
      });
      if (!respuesta.ok) {
        setError(await mensajeDeError(respuesta, "No se pudo disparar la corrida."));
        return;
      }
      cargar();
    } catch {
      setError("No se pudo disparar la corrida. Revisa tu conexión e intenta de nuevo.");
    } finally {
      setDisparando(null);
    }
  }

  const corridasOrdenadas = [...corridas].sort((a, b) => b.fecha.localeCompare(a.fecha));

  const metricas = useMemo(
    () => ({
      total: corridas.length,
      exitosas: corridas.filter((c) => c.estado === "exitosa").length,
      fallidas: corridas.filter((c) => c.estado === "fallida").length,
      enProgreso: corridas.filter((c) => c.estado === "en_progreso").length,
    }),
    [corridas],
  );

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <strong>Corridas de batch</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Corridas de batch</h1>
            <p className="subtitulo-pagina">
              Estado de las corridas automáticas y disparo manual por tipo de batch.
            </p>
          </div>
        </div>

        {estadoCarga === "listo" && corridas.length > 0 && (
          <div className="banda-metricas">
            <div className="metrica">
              <span className="etiqueta-metrica">Corridas registradas</span>
              <strong>{metricas.total}</strong>
            </div>
            <div className="metrica">
              <span className="etiqueta-metrica">
                <span className="punto punto--exito" aria-hidden="true" />
                Exitosas
              </span>
              <strong>{metricas.exitosas}</strong>
            </div>
            <div className="metrica">
              <span className="etiqueta-metrica">
                <span className="punto punto--aviso" aria-hidden="true" />
                En progreso
              </span>
              <strong>{metricas.enProgreso}</strong>
            </div>
            <div className="metrica">
              <span className="etiqueta-metrica">
                <span className="punto punto--peligro" aria-hidden="true" />
                Fallidas
              </span>
              <strong>{metricas.fallidas}</strong>
            </div>
          </div>
        )}

        <div className="rejilla-acciones">
          {TIPOS_BATCH_DISPARABLES.map(({ codigo, ruta, etiqueta, descripcion, icono: Icono }) => (
            <div className="tarjeta-accion" key={codigo}>
              <span className="icono-seccion">
                <Icono size={20} aria-hidden="true" />
              </span>
              <strong>{etiqueta}</strong>
              <p>{descripcion}</p>
              <label>
                Fecha a procesar
                <input
                  type="date"
                  value={fechas[codigo]}
                  onChange={(evento) =>
                    setFechas((anteriores) => ({ ...anteriores, [codigo]: evento.target.value }))
                  }
                />
              </label>
              <Button
                type="button"
                variante="primario"
                icono={PlayCircle}
                posicionIcono="izquierda"
                cargando={disparando === codigo}
                textoCargando="Disparando…"
                aria-label={`Disparar ${etiqueta}`}
                onClick={() => dispararBatch(codigo, ruta)}
              >
                Disparar
              </Button>
            </div>
          ))}
        </div>

        {error && <p role="alert">{error}</p>}

        {estadoCarga === "cargando" && (
          <p className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando corridas…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar el listado de corridas
            </strong>
            <p>Ocurrió un problema al consultar el estado de los batches.</p>
            <button type="button" onClick={cargar}>
              Reintentar
            </button>
          </div>
        )}

        {estadoCarga === "listo" && corridasOrdenadas.length === 0 && (
          <div className="estado-vacio">
            <p>Todavía no hay corridas registradas.</p>
          </div>
        )}

        {estadoCarga === "listo" && corridasOrdenadas.length > 0 && (
          <div className="tabla-desplazable">
            <table>
              <thead>
                <tr>
                  <th>Tipo de batch</th>
                  <th>Fecha</th>
                  <th>Estado</th>
                  <th>Intentos</th>
                  <th>Iniciado</th>
                  <th>Terminado</th>
                  <th>Detalle</th>
                </tr>
              </thead>
              <tbody>
                {corridasOrdenadas.map((corrida) => (
                  <tr key={corrida.id}>
                    <td>{ETIQUETA_TIPO_BATCH[corrida.tipo_batch] ?? corrida.tipo_batch}</td>
                    <td>{corrida.fecha}</td>
                    <td>
                      <Badge variante={VARIANTE_ESTADO[corrida.estado]}>
                        {ETIQUETA_ESTADO[corrida.estado]}
                      </Badge>
                    </td>
                    <td>{corrida.intentos}</td>
                    <td>{formatearFechaHora(corrida.iniciado_en)}</td>
                    <td>{formatearFechaHora(corrida.terminado_en)}</td>
                    <td>{corrida.detalle ?? "—"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </AppShell>
  );
}
