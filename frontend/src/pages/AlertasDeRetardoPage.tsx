import { useEffect, useMemo, useState } from "react";
import { AlertCircle, AlertTriangle, Loader2 } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Badge } from "../components/Badge";
import { Input } from "../components/Input";

// Ventana por defecto al entrar a la pantalla — 14 días (una quincena) es un rango chico que
// entra bien en pantalla sin pegarle al tope de 62 días (LIMITE_RANGO_DIAS en el backend) ni
// dejar la tabla vacía por defecto.
const DIAS_VENTANA_POR_DEFECTO = 13;

type Persona = {
  id: string;
  primer_nombre: string;
  apellido_paterno: string;
};

type Motivo = "sin_marcas" | "fuera_de_tolerancia";

type Alerta = {
  persona_id: string;
  persona_nombre: string | null;
  fecha: string;
  hora_entrada_programada: string;
  hora_salida_programada: string;
  primera_marca: string | null;
  ultima_marca: string | null;
  motivo: Motivo;
};

type EstadoCarga = "cargando" | "listo" | "error";

const ETIQUETA_MOTIVO: Record<Motivo, string> = {
  sin_marcas: "Sin marcas ese día",
  fuera_de_tolerancia: "Fuera de tolerancia",
};

function aFechaISO(fecha: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${fecha.getFullYear()}-${pad(fecha.getMonth() + 1)}-${pad(fecha.getDate())}`;
}

function formatearFecha(fecha: string): string {
  const valor = new Date(`${fecha}T00:00:00`);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" });
}

function formatearHoraProgramada(hora: string): string {
  // hora_entrada_programada/hora_salida_programada llegan "HH:MM:SS" (time de Postgres).
  return hora.slice(0, 5);
}

function formatearHoraMarca(fecha: string | null): string {
  if (!fecha) return "—";
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleTimeString("es-MX", { hour: "2-digit", minute: "2-digit" });
}

async function mensajeDeError(respuesta: Response, generico: string): Promise<string> {
  try {
    const cuerpo = await respuesta.json();
    if (typeof cuerpo?.detail === "string") return cuerpo.detail;
  } catch {
    // cuerpo no era JSON legible — cae al genérico
  }
  return generico;
}

export function AlertasDeRetardoPage() {
  const [personas, setPersonas] = useState<Persona[]>([]);
  const [alertas, setAlertas] = useState<Alerta[]>([]);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [error, setError] = useState<string | null>(null);
  const [personaId, setPersonaId] = useState(
    () => new URLSearchParams(window.location.search).get("persona_id") ?? "",
  );
  const [desde, setDesde] = useState(() => {
    const hoy = new Date();
    const inicio = new Date(hoy);
    inicio.setDate(hoy.getDate() - DIAS_VENTANA_POR_DEFECTO);
    return aFechaISO(inicio);
  });
  const [hasta, setHasta] = useState(() => aFechaISO(new Date()));

  useEffect(() => {
    apiFetch("/api/personas")
      .then((r) => (r.ok ? r.json() : []))
      .then((datos: Persona[]) =>
        setPersonas([...datos].sort((a, b) => a.primer_nombre.localeCompare(b.primer_nombre))),
      )
      .catch(() => setPersonas([]));
  }, []);

  function cargar() {
    // desde/hasta son requeridos sin default en el backend (a diferencia de TramosPage/DiasPage) --
    // si el usuario borra cualquiera de los 2 inputs, no hay nada válido que pedir: cortamos antes
    // del fetch en vez de mandar un 422 y caer al estado de error genérico.
    if (!desde || !hasta) {
      setAlertas([]);
      setError(null);
      setEstadoCarga("listo");
      return;
    }
    setEstadoCarga("cargando");
    setError(null);
    const params = new URLSearchParams({ desde, hasta });
    if (personaId) params.set("persona_id", personaId);
    apiFetch(`/api/alertas-de-retardo?${params.toString()}`)
      .then(async (respuesta) => {
        if (!respuesta.ok) {
          setError(await mensajeDeError(respuesta, "No se pudo cargar las alertas de retardo."));
          setEstadoCarga("error");
          return;
        }
        const datos: { alertas: Alerta[] } = await respuesta.json();
        setAlertas(datos.alertas);
        setEstadoCarga("listo");
      })
      .catch(() => {
        setError("No se pudo cargar las alertas de retardo. Revisa tu conexión e intenta de nuevo.");
        setEstadoCarga("error");
      });
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [personaId, desde, hasta]);

  const opcionesPersona = useMemo(
    () => personas.map((p) => ({ id: p.id, nombre: `${p.primer_nombre} ${p.apellido_paterno}` })),
    [personas],
  );

  const rangoIncompleto = !desde || !hasta;

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <strong>Alertas de retardo</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Alertas de retardo</h1>
            <p className="subtitulo-pagina">
              Días con jornada normal donde la entrada o la salida no coincidió con lo programado.
            </p>
          </div>
        </div>

        <div className="barra-filtros">
          <select
            value={personaId}
            onChange={(evento) => setPersonaId(evento.target.value)}
            aria-label="Filtrar por persona"
          >
            <option value="">Persona: Todas</option>
            {opcionesPersona.map((persona) => (
              <option key={persona.id} value={persona.id}>
                {persona.nombre}
              </option>
            ))}
          </select>
          <div className="grupo-filtros-secundarios">
            <Input
              id="alertas-desde"
              label="Desde"
              type="date"
              value={desde}
              onChange={(evento) => setDesde(evento.target.value)}
            />
            <Input
              id="alertas-hasta"
              label="Hasta"
              type="date"
              value={hasta}
              onChange={(evento) => setHasta(evento.target.value)}
            />
          </div>
        </div>

        {estadoCarga === "cargando" && (
          <p className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando alertas…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar las alertas de retardo
            </strong>
            <p>{error}</p>
            <button type="button" onClick={cargar}>
              Reintentar
            </button>
          </div>
        )}

        {estadoCarga === "listo" && alertas.length === 0 && (
          <div className="estado-vacio">
            <AlertTriangle size={28} aria-hidden="true" />
            <p>
              {rangoIncompleto
                ? "Selecciona un rango de fechas (Desde y Hasta) para ver alertas."
                : "Sin alertas de retardo en el rango seleccionado."}
            </p>
          </div>
        )}

        {estadoCarga === "listo" && alertas.length > 0 && (
          <div className="tabla-desplazable">
            <table>
              <thead>
                <tr>
                  <th>Persona</th>
                  <th>Fecha</th>
                  <th>Entrada programada</th>
                  <th>Salida programada</th>
                  <th>Primera marca</th>
                  <th>Última marca</th>
                  <th>Motivo</th>
                </tr>
              </thead>
              <tbody>
                {alertas.map((alerta) => (
                  <tr key={`${alerta.persona_id}-${alerta.fecha}`}>
                    <td>{alerta.persona_nombre ?? "—"}</td>
                    <td>{formatearFecha(alerta.fecha)}</td>
                    <td>{formatearHoraProgramada(alerta.hora_entrada_programada)}</td>
                    <td>{formatearHoraProgramada(alerta.hora_salida_programada)}</td>
                    <td>{formatearHoraMarca(alerta.primera_marca)}</td>
                    <td>{formatearHoraMarca(alerta.ultima_marca)}</td>
                    <td>
                      <Badge variante={alerta.motivo === "sin_marcas" ? "peligro" : "aviso"}>
                        {ETIQUETA_MOTIVO[alerta.motivo]}
                      </Badge>
                    </td>
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
