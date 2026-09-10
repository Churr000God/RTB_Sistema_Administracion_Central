import { useEffect, useMemo, useRef, useState } from "react";
import { AlertCircle, Loader2, RadioTower, Search, Wrench } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { etiquetaMotivo } from "../lib/motivosRevision";
import { AppShell } from "../layouts/AppShell";
import { Badge } from "../components/Badge";
import { Input } from "../components/Input";

// Intervalo de refresco del feed — "en vivo" vía polling, sin websocket (mismo criterio que
// documentó backend en marcas.py: SCJ-PRO-11/07 no piden push real). 20s cae dentro del rango
// razonable (15-30s) pedido por el usuario: rápido para sentirse "en vivo", sin saturar al
// backend con un refresco por segundo.
const INTERVALO_REFRESCO_MS = 20_000;
const LIMITE = 100;

type Persona = {
  id: string;
  primer_nombre: string;
  apellido_paterno: string;
};

type Marca = {
  id: number;
  evento_id: string;
  persona_id: string;
  persona_nombre: string | null;
  terminal_id: string;
  secuencia_local: number | null;
  momento_dispositivo: string;
  momento_efectivo: string;
  desfase_local: string;
  momento_recepcion: string;
  estado_reloj: "sincronizado" | "deriva" | "sin_sincronizar";
  origen: "terminal" | "captura_manual";
  version_software: string;
  requiere_revision: boolean;
  estado_revision: "sin_revision" | "pendiente" | "resuelta";
  motivos_revision: string[];
  excepcion_pendiente_id: number | null;
};

type RespuestaMarcas = { total: number; marcas: Marca[] };

type EstadoCarga = "cargando" | "listo" | "error";

const ETIQUETA_ORIGEN: Record<Marca["origen"], string> = {
  terminal: "Terminal",
  captura_manual: "Captura manual",
};

const ETIQUETA_ESTADO_RELOJ: Record<Marca["estado_reloj"], string> = {
  sincronizado: "Sincronizado",
  deriva: "Con deriva",
  sin_sincronizar: "Sin sincronizar",
};

const VARIANTE_ESTADO_RELOJ: Record<Marca["estado_reloj"], "exito" | "aviso" | "peligro"> = {
  sincronizado: "exito",
  deriva: "aviso",
  sin_sincronizar: "peligro",
};

// "resuelta" reusa la variante "exito" — mismo criterio que "Vigente" en ParametrosSistemaPage:
// no es un mensaje de éxito de una acción, es un estado cerrado/sin pendiente, la lectura visual
// que ya tiene esa variante en el proyecto.
const ETIQUETA_ESTADO_REVISION: Record<"pendiente" | "resuelta", string> = {
  pendiente: "Requiere revisión",
  resuelta: "Revisión resuelta",
};

const VARIANTE_ESTADO_REVISION: Record<"pendiente" | "resuelta", "aviso" | "exito"> = {
  pendiente: "aviso",
  resuelta: "exito",
};

function formatearFechaHora(fecha: string): string {
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleString("es-MX", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function formatearHoraCorta(fecha: Date): string {
  return fecha.toLocaleTimeString("es-MX", { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

export function RegistroMarcasPage() {
  const [personas, setPersonas] = useState<Persona[]>([]);
  const [marcas, setMarcas] = useState<Marca[]>([]);
  const [total, setTotal] = useState(0);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [personaId, setPersonaId] = useState("");
  const [desde, setDesde] = useState("");
  const [hasta, setHasta] = useState("");
  const [ultimaActualizacion, setUltimaActualizacion] = useState<Date | null>(null);
  // Evita que un refresco automático en curso (polling) pise el spinner de una carga manual
  // (cambio de filtro) o viceversa — sólo la carga manual muestra el estado "cargando" a
  // pantalla completa, el refresco silencioso no debe hacer parpadear la tabla ya visible.
  const cargaEnCursoRef = useRef(0);

  useEffect(() => {
    apiFetch("/api/personas")
      .then((r) => (r.ok ? r.json() : []))
      .then((datos: Persona[]) =>
        setPersonas([...datos].sort((a, b) => a.primer_nombre.localeCompare(b.primer_nombre))),
      )
      .catch(() => setPersonas([]));
  }, []);

  useEffect(() => {
    const params = new URLSearchParams();
    if (personaId) params.set("persona_id", personaId);
    if (desde) params.set("desde", new Date(desde).toISOString());
    if (hasta) params.set("hasta", new Date(hasta).toISOString());
    params.set("limite", String(LIMITE));

    function cargar(silencioso: boolean) {
      const idCarga = ++cargaEnCursoRef.current;
      if (!silencioso) setEstadoCarga("cargando");
      apiFetch(`/api/marcas?${params.toString()}`)
        .then((respuesta) => {
          if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
          return respuesta.json();
        })
        .then((datos: RespuestaMarcas) => {
          if (idCarga !== cargaEnCursoRef.current) return; // una carga más nueva ya arrancó
          setMarcas(datos.marcas);
          setTotal(datos.total);
          setEstadoCarga("listo");
          setUltimaActualizacion(new Date());
        })
        .catch(() => {
          if (idCarga !== cargaEnCursoRef.current) return;
          setEstadoCarga("error");
        });
    }

    cargar(false);
    const intervalo = setInterval(() => cargar(true), INTERVALO_REFRESCO_MS);
    return () => clearInterval(intervalo);
  }, [personaId, desde, hasta]);

  const opcionesPersona = useMemo(
    () => personas.map((p) => ({ id: p.id, nombre: `${p.primer_nombre} ${p.apellido_paterno}` })),
    [personas],
  );

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <strong>Registro de marcas</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Registro de marcas</h1>
            <p className="subtitulo-pagina">
              "Ocurrió" es la hora real del evento según el reloj del dispositivo — la que calcula
              la jornada. "Recibida" es sólo cuándo llegó al servidor y nunca entra en ese cálculo.
              El feed se refresca solo cada {INTERVALO_REFRESCO_MS / 1000} segundos.
            </p>
          </div>
        </div>

        <div className="barra-filtros">
          <div className="campo-con-icono">
            <Search size={16} className="icono-campo" aria-hidden="true" />
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
          </div>
          <div className="grupo-filtros-secundarios">
            <Input
              id="filtro-marca-desde"
              label="Desde"
              type="datetime-local"
              value={desde}
              onChange={(evento) => setDesde(evento.target.value)}
            />
            <Input
              id="filtro-marca-hasta"
              label="Hasta"
              type="datetime-local"
              value={hasta}
              onChange={(evento) => setHasta(evento.target.value)}
            />
          </div>
        </div>

        <p className="boton-con-icono indicador-en-vivo">
          <RadioTower size={14} aria-hidden="true" />
          {ultimaActualizacion
            ? `En vivo · última actualización ${formatearHoraCorta(ultimaActualizacion)}`
            : "En vivo"}
        </p>

        {estadoCarga === "cargando" && (
          <p className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando marcas…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar el registro de marcas
            </strong>
            <p>Ocurrió un problema al consultar las marcas.</p>
          </div>
        )}

        {estadoCarga === "listo" && marcas.length === 0 && (
          <div className="estado-vacio">
            <p>No hay marcas que coincidan con la búsqueda.</p>
          </div>
        )}

        {estadoCarga === "listo" && marcas.length > 0 && (
          <>
            <div className="tabla-desplazable">
              <table>
                <thead>
                  <tr>
                    <th>Persona</th>
                    <th>Terminal</th>
                    <th>Origen</th>
                    <th>Reloj</th>
                    <th>Ocurrió</th>
                    <th>Recibida</th>
                    <th>Revisión</th>
                    <th>Acciones</th>
                  </tr>
                </thead>
                <tbody>
                  {marcas.map((marca) => (
                    <tr key={marca.id}>
                      <td>{marca.persona_nombre ?? "—"}</td>
                      <td>{marca.terminal_id}</td>
                      <td>{ETIQUETA_ORIGEN[marca.origen]}</td>
                      <td>
                        <Badge variante={VARIANTE_ESTADO_RELOJ[marca.estado_reloj]}>
                          {ETIQUETA_ESTADO_RELOJ[marca.estado_reloj]}
                        </Badge>
                      </td>
                      <td>
                        {formatearFechaHora(marca.momento_efectivo)} ({marca.desfase_local})
                        {marca.momento_efectivo !== marca.momento_dispositivo && (
                          <div className="ayuda-campo">
                            Original: {formatearFechaHora(marca.momento_dispositivo)}
                          </div>
                        )}
                      </td>
                      <td>{formatearFechaHora(marca.momento_recepcion)}</td>
                      <td>
                        {marca.estado_revision === "sin_revision" ? (
                          "—"
                        ) : (
                          <>
                            <Badge variante={VARIANTE_ESTADO_REVISION[marca.estado_revision]}>
                              {ETIQUETA_ESTADO_REVISION[marca.estado_revision]}
                            </Badge>
                            {marca.motivos_revision.length > 0 && (
                              <div className="ayuda-campo">
                                {marca.motivos_revision.map((motivo) => etiquetaMotivo(motivo)).join(", ")}
                              </div>
                            )}
                          </>
                        )}
                      </td>
                      <td>
                        {marca.excepcion_pendiente_id !== null ? (
                          <a
                            href={`/tiempo/excepciones/${marca.excepcion_pendiente_id}/corregir`}
                            className="boton-con-icono"
                          >
                            <Wrench size={14} aria-hidden="true" />
                            Corregir
                          </a>
                        ) : (
                          "—"
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="pie-tabla">
              Mostrando {marcas.length} de {total} marcas
              {total > marcas.length && " · afiná los filtros para ver el resto"}
            </p>
          </>
        )}
      </div>
    </AppShell>
  );
}
