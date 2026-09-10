import { useEffect, useRef, useState } from "react";
import { AlertCircle, Loader2, Search } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Badge } from "../components/Badge";
import { Button } from "../components/Button";
import { Input } from "../components/Input";

// Debounce del buscador de persona: es el único filtro de esta pantalla sin precedente de
// "dispara al toque" (los demás son select/date, que sí lo hacen) — texto libre resuelto en el
// backend necesita esperar a que la persona termine de teclear.
const DEBOUNCE_BUSQUEDA_MS = 300;
const LIMITE = 20;

type Tramo = {
  id: number;
  fecha: string;
  persona_id: string;
  persona_nombre: string | null;
  inicio: string;
  fin: string | null;
  minutos_trabajados: number | null;
  dia_estado: "abierto" | "cerrado" | "bloqueado" | "revisado";
  tipo: "ordinario" | "reposicion" | "extra" | null;
};

type RespuestaTramos = { total: number; tramos: Tramo[] };

type EstadoCarga = "cargando" | "listo" | "error";

type Orden = "inicio_desc" | "inicio_asc" | "minutos_desc" | "minutos_asc";

function formatearFecha(fecha: string): string {
  const valor = new Date(`${fecha}T00:00:00`);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" });
}

function formatearHora(fecha: string | null): string {
  if (!fecha) return "—";
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleTimeString("es-MX", { hour: "2-digit", minute: "2-digit" });
}

function formatearMinutos(minutos: number | null): string {
  if (minutos === null) return "—";
  const horas = Math.floor(minutos / 60);
  const resto = Math.round(minutos % 60);
  return `${horas}h ${resto}m`;
}

// "abierto"/"cerrado" son los estados normales del ciclo de vida del día -- no llevan badge.
// Sólo "bloqueado" (SCJ-DEC-06: paridad impar al cierre, no se reabre solo) y "revisado" son
// desvíos que valen aviso visual en esta pantalla de sólo lectura.
const ETIQUETA_DIA_ESTADO: Partial<Record<Tramo["dia_estado"], string>> = {
  bloqueado: "Bloqueado — necesita revisión",
  revisado: "Revisado",
};

const VARIANTE_DIA_ESTADO: Partial<Record<Tramo["dia_estado"], "peligro" | "exito">> = {
  bloqueado: "peligro",
  revisado: "exito",
};

// null = todavía no corrió el corte quincenal (SCJ-PRO-13) sobre este tramo -- normal en uno
// reciente o "en curso", no es una alerta, por eso va en texto plano sin badge.
const ETIQUETA_TIPO: Record<Exclude<Tramo["tipo"], null>, string> = {
  ordinario: "Ordinario",
  reposicion: "Reposición",
  extra: "Extra",
};

const VARIANTE_TIPO: Record<Exclude<Tramo["tipo"], null>, "neutra" | "aviso" | "exito"> = {
  ordinario: "neutra",
  reposicion: "aviso",
  extra: "exito",
};

export function TramosPage() {
  const [tramos, setTramos] = useState<Tramo[]>([]);
  const [total, setTotal] = useState(0);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [busqueda, setBusqueda] = useState("");
  const [busquedaDebounced, setBusquedaDebounced] = useState("");
  const [desde, setDesde] = useState("");
  const [hasta, setHasta] = useState("");
  const [orden, setOrden] = useState<Orden>("inicio_desc");
  const [desplazamiento, setDesplazamiento] = useState(0);
  // Mismo propósito que RegistroMarcasPage: con debounce + filtros encadenados las respuestas
  // pueden llegar fuera de orden — sólo la más nueva gana.
  const cargaEnCursoRef = useRef(0);

  useEffect(() => {
    const id = setTimeout(() => {
      setBusquedaDebounced(busqueda.trim());
      setDesplazamiento(0);
    }, DEBOUNCE_BUSQUEDA_MS);
    return () => clearTimeout(id);
  }, [busqueda]);

  function cargar() {
    const params = new URLSearchParams();
    if (busquedaDebounced) params.set("busqueda_persona", busquedaDebounced);
    if (desde) params.set("desde", desde);
    if (hasta) params.set("hasta", hasta);
    params.set("orden", orden);
    params.set("limite", String(LIMITE));
    params.set("desplazamiento", String(desplazamiento));

    const idCarga = ++cargaEnCursoRef.current;
    setEstadoCarga("cargando");
    apiFetch(`/api/tramos?${params.toString()}`)
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datos: RespuestaTramos) => {
        if (idCarga !== cargaEnCursoRef.current) return;
        setTramos(datos.tramos);
        setTotal(datos.total);
        setEstadoCarga("listo");
      })
      .catch(() => {
        if (idCarga !== cargaEnCursoRef.current) return;
        setEstadoCarga("error");
      });
  }

  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(cargar, [busquedaDebounced, desde, hasta, orden, desplazamiento]);

  const hayFiltrosActivos = !!(busqueda || desde || hasta);

  function limpiarFiltros() {
    setBusqueda("");
    setBusquedaDebounced("");
    setDesde("");
    setHasta("");
    setDesplazamiento(0);
  }

  const paginaActual = Math.floor(desplazamiento / LIMITE) + 1;
  const hayPaginaAnterior = desplazamiento > 0;
  const hayPaginaSiguiente = desplazamiento + LIMITE < total;

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <strong>Tramos</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Tramos</h1>
            <p className="subtitulo-pagina">
              Cada tramo es el par de marcas de entrada y salida que calcula el cierre de día.
              Sólo consulta — un tramo sin fin todavía está "En curso".
            </p>
          </div>
        </div>

        <div className="barra-filtros">
          <div className="campo-con-icono">
            <Search size={16} className="icono-campo" aria-hidden="true" />
            <input
              type="search"
              placeholder="Buscar por persona"
              value={busqueda}
              onChange={(evento) => setBusqueda(evento.target.value)}
              aria-label="Buscar por persona"
            />
          </div>
          <div className="grupo-filtros-secundarios">
            <Input
              id="filtro-tramo-desde"
              label="Desde"
              type="date"
              value={desde}
              onChange={(evento) => {
                setDesde(evento.target.value);
                setDesplazamiento(0);
              }}
            />
            <Input
              id="filtro-tramo-hasta"
              label="Hasta"
              type="date"
              value={hasta}
              onChange={(evento) => {
                setHasta(evento.target.value);
                setDesplazamiento(0);
              }}
            />
            <select
              value={orden}
              onChange={(evento) => {
                setOrden(evento.target.value as Orden);
                setDesplazamiento(0);
              }}
              aria-label="Ordenar por"
            >
              <option value="inicio_desc">Inicio: más recientes primero</option>
              <option value="inicio_asc">Inicio: más antiguos primero</option>
              <option value="minutos_desc">Minutos trabajados: mayor primero</option>
              <option value="minutos_asc">Minutos trabajados: menor primero</option>
            </select>
            {hayFiltrosActivos && (
              <Button type="button" onClick={limpiarFiltros}>
                Limpiar filtros
              </Button>
            )}
          </div>
        </div>

        {estadoCarga === "cargando" && (
          <p className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando tramos…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudieron cargar los tramos
            </strong>
            <p>Ocurrió un problema al consultar los tramos.</p>
            <Button type="button" onClick={cargar}>
              Reintentar
            </Button>
          </div>
        )}

        {estadoCarga === "listo" && tramos.length === 0 && (
          <div className="estado-vacio">
            <p>No hay tramos que coincidan con la búsqueda.</p>
          </div>
        )}

        {estadoCarga === "listo" && tramos.length > 0 && (
          <>
            <div className="tabla-desplazable">
              <table>
                <thead>
                  <tr>
                    <th>Tramo</th>
                    <th>Día</th>
                    <th>Persona</th>
                    <th>Inicio</th>
                    <th>Fin</th>
                    <th>Minutos trabajados</th>
                    <th>Estado del día</th>
                    <th>Tipo</th>
                  </tr>
                </thead>
                <tbody>
                  {tramos.map((tramo) => (
                    <tr key={tramo.id}>
                      <td>{tramo.id}</td>
                      <td>{formatearFecha(tramo.fecha)}</td>
                      <td>{tramo.persona_nombre ?? "—"}</td>
                      <td>{formatearHora(tramo.inicio)}</td>
                      <td>
                        {tramo.fin === null ? (
                          tramo.dia_estado === "abierto" ? (
                            <Badge variante="aviso">En curso</Badge>
                          ) : (
                            <Badge variante="peligro">Sin cierre (día {tramo.dia_estado})</Badge>
                          )
                        ) : (
                          formatearHora(tramo.fin)
                        )}
                      </td>
                      <td>{formatearMinutos(tramo.minutos_trabajados)}</td>
                      <td>
                        {(() => {
                          const variante = VARIANTE_DIA_ESTADO[tramo.dia_estado];
                          return variante ? (
                            <Badge variante={variante}>{ETIQUETA_DIA_ESTADO[tramo.dia_estado]}</Badge>
                          ) : (
                            "—"
                          );
                        })()}
                      </td>
                      <td>
                        {tramo.tipo === null ? (
                          "Sin clasificar"
                        ) : (
                          <Badge variante={VARIANTE_TIPO[tramo.tipo]}>{ETIQUETA_TIPO[tramo.tipo]}</Badge>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="pie-tabla">
              Mostrando {tramos.length} de {total} tramos
            </p>
            <div className="botonera">
              <Button
                type="button"
                onClick={() => setDesplazamiento((actual) => Math.max(0, actual - LIMITE))}
                disabled={!hayPaginaAnterior}
              >
                Anterior
              </Button>
              <span className="ayuda-campo">Página {paginaActual}</span>
              <Button
                type="button"
                onClick={() => setDesplazamiento((actual) => actual + LIMITE)}
                disabled={!hayPaginaSiguiente}
              >
                Siguiente
              </Button>
            </div>
          </>
        )}
      </div>
    </AppShell>
  );
}
