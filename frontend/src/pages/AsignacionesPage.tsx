import { useEffect, useMemo, useState } from "react";
import { AlertCircle, ArrowRight, Loader2, Plus, Repeat, Search, Users } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Badge } from "../components/Badge";
import { Input } from "../components/Input";
import {
  construirBosque,
  descendientesIncluidoSiMismo,
  filtrarBosque,
  Organigrama,
  type PuestoOrganigrama,
} from "../components/Organigrama";

type Asignacion = {
  id: string;
  persona_id: string;
  persona_nombre: string;
  puesto_id: string;
  nombre_puesto: string;
  nombre_departamento: string;
  nombre_area: string;
  vigente_desde: string;
  vigente_hasta: string | null;
};

type EstadoCarga = "cargando" | "listo" | "error";
type EstadoCatalogo = "cargando" | "listo" | "error" | "sin_permiso";
type FiltroRama = { puestoId: string; nombrePuesto: string };

function normalizar(texto: string): string {
  return texto
    .normalize("NFD")
    .replace(new RegExp("[\\u0300-\\u036f]", "g"), "")
    .toLowerCase();
}

function formatearFecha(fecha?: string | null): string {
  if (!fecha) return "—";
  const valor = new Date(fecha.includes("T") ? fecha : `${fecha}T00:00:00`);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" });
}

function inicialesDe(nombre: string): string {
  const partes = nombre.trim().split(/\s+/);
  return `${partes[0]?.[0] ?? ""}${partes[partes.length - 1]?.[0] ?? ""}`.toUpperCase();
}

export function AsignacionesPage() {
  const [asignaciones, setAsignaciones] = useState<Asignacion[]>([]);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [busqueda, setBusqueda] = useState("");
  const [filtroEstado, setFiltroEstado] = useState("");
  const [orden, setOrden] = useState<"desc" | "asc">("desc");
  const [filtroDesde, setFiltroDesde] = useState("");
  const [filtroHasta, setFiltroHasta] = useState("");
  const [vista, setVista] = useState<"tabla" | "organigrama">("tabla");
  const [busquedaOrganigrama, setBusquedaOrganigrama] = useState("");
  const [filtroRama, setFiltroRama] = useState<FiltroRama | null>(null);
  const [puestos, setPuestos] = useState<PuestoOrganigrama[]>([]);
  const [estadoPuestos, setEstadoPuestos] = useState<EstadoCatalogo>("cargando");

  function cargar() {
    setEstadoCarga("cargando");
    apiFetch("/api/asignaciones")
      .then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      })
      .then((datos: Asignacion[]) => {
        setAsignaciones(datos);
        setEstadoCarga("listo");
      })
      .catch(() => setEstadoCarga("error"));

    // Gate propio (puesto_lectura/edicion) — el organigrama es dato de puesto, no de
    // asignación, y se pide y degrada por separado del historial de arriba.
    setEstadoPuestos("cargando");
    apiFetch("/api/puestos")
      .then((r) => {
        if (r.status === 403) throw new Error("sin_permiso");
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      })
      .then((datos: PuestoOrganigrama[]) => {
        setPuestos(datos);
        setEstadoPuestos("listo");
      })
      .catch((e: Error) => setEstadoPuestos(e.message === "sin_permiso" ? "sin_permiso" : "error"));
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const ocupadasPorPuesto = useMemo(() => {
    const conteo: Record<string, number> = {};
    for (const a of asignaciones) {
      if (a.vigente_hasta) continue;
      conteo[a.puesto_id] = (conteo[a.puesto_id] ?? 0) + 1;
    }
    return conteo;
  }, [asignaciones]);

  const bosque = useMemo(() => construirBosque(puestos), [puestos]);
  const bosqueFiltrado = useMemo(
    () => filtrarBosque(bosque, busquedaOrganigrama.trim().toLowerCase()),
    [bosque, busquedaOrganigrama],
  );

  function handleSeleccionarPuesto(puesto: PuestoOrganigrama) {
    setFiltroRama({ puestoId: puesto.id, nombrePuesto: puesto.nombre_puesto });
    setVista("tabla");
  }

  const metricas = useMemo(
    () => ({
      total: asignaciones.length,
      vigentes: asignaciones.filter((a) => !a.vigente_hasta).length,
      terminadas: asignaciones.filter((a) => a.vigente_hasta).length,
    }),
    [asignaciones],
  );

  // Independiente de si /api/puestos falló o no: si no hay puestos cargados, la rama filtrada
  // queda vacía (conjunto sólo con el propio puesto_id) en vez de romper el filtro.
  const ramaFiltrada = useMemo(
    () => (filtroRama ? descendientesIncluidoSiMismo(puestos, filtroRama.puestoId) : null),
    [puestos, filtroRama],
  );

  const filtradas = useMemo(() => {
    const consulta = normalizar(busqueda.trim());
    const desde = filtroDesde ? new Date(`${filtroDesde}T00:00:00`) : null;
    const hasta = filtroHasta ? new Date(`${filtroHasta}T00:00:00`) : null;
    const direccion = orden === "desc" ? -1 : 1;
    return [...asignaciones]
      .sort(
        (a, b) =>
          direccion * (new Date(a.vigente_desde).getTime() - new Date(b.vigente_desde).getTime()),
      )
      .filter((a) => {
        const coincideBusqueda =
          !consulta ||
          normalizar(a.persona_nombre).includes(consulta) ||
          normalizar(a.nombre_puesto).includes(consulta);
        const coincideEstado =
          !filtroEstado || (filtroEstado === "vigente" ? !a.vigente_hasta : !!a.vigente_hasta);
        const fechaVigenteDesde = new Date(a.vigente_desde);
        const coincideDesde = !desde || fechaVigenteDesde >= desde;
        const coincideHasta = !hasta || fechaVigenteDesde <= hasta;
        const coincideRama = !ramaFiltrada || ramaFiltrada.has(a.puesto_id);
        return coincideBusqueda && coincideEstado && coincideDesde && coincideHasta && coincideRama;
      });
  }, [asignaciones, busqueda, filtroEstado, orden, filtroDesde, filtroHasta, ramaFiltrada]);

  const agrupadasPorAnio = useMemo(() => {
    const grupos = new Map<string, Asignacion[]>();
    for (const asignacion of filtradas) {
      const anio = new Date(asignacion.vigente_desde).getFullYear().toString();
      const lista = grupos.get(anio) ?? [];
      lista.push(asignacion);
      grupos.set(anio, lista);
    }
    return grupos;
  }, [filtradas]);

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          Estructura organizacional › <strong>Asignaciones</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Asignaciones</h1>
            <p className="subtitulo-pagina">Historial de personas asignadas a puestos.</p>
          </div>
          <Button
            href="/estructura/asignaciones/nueva"
            variante="primario"
            icono={Plus}
            posicionIcono="izquierda"
          >
            Nueva asignación
          </Button>
        </div>

        <div className="pestanas" role="tablist" aria-label="Vista de asignaciones">
          <button
            type="button"
            role="tab"
            aria-selected={vista === "tabla"}
            className={`pestana${vista === "tabla" ? " pestana--activa" : ""}`}
            onClick={() => setVista("tabla")}
          >
            Tabla
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={vista === "organigrama"}
            className={`pestana${vista === "organigrama" ? " pestana--activa" : ""}`}
            onClick={() => setVista("organigrama")}
          >
            Organigrama
          </button>
        </div>

        {vista === "organigrama" && (
          <div role="tabpanel">
            {estadoPuestos === "sin_permiso" && <p>No tienes permiso para ver el organigrama.</p>}
            {estadoPuestos === "error" && <p>No se pudo cargar el organigrama.</p>}
            {estadoPuestos === "cargando" && (
              <p className="boton-con-icono">
                <Loader2 size={16} className="icono-girando" aria-hidden="true" />
                Cargando organigrama…
              </p>
            )}
            {estadoPuestos === "listo" && (
              <>
                <div className="campo-con-icono">
                  <Search size={16} className="icono-campo" aria-hidden="true" />
                  <input
                    type="search"
                    placeholder="Buscar puesto en el organigrama"
                    value={busquedaOrganigrama}
                    onChange={(evento) => setBusquedaOrganigrama(evento.target.value)}
                    aria-label="Buscar puesto en el organigrama"
                  />
                </div>
                {bosque.length > 0 && bosqueFiltrado.length === 0 && (
                  <p>Ningún puesto coincide con la búsqueda.</p>
                )}
                {bosque.length === 0 && <p>No hay puestos registrados todavía.</p>}
                {bosqueFiltrado.length > 0 && (
                  <Organigrama
                    bosque={bosqueFiltrado}
                    ocupadasPorPuesto={ocupadasPorPuesto}
                    onSeleccionarPuesto={handleSeleccionarPuesto}
                  />
                )}
              </>
            )}
          </div>
        )}

        {vista === "tabla" && (
        <div role="tabpanel">
        {filtroRama && (
          <div className="chip-filtro">
            Filtrado por: {filtroRama.nombrePuesto} y su equipo
            <button
              type="button"
              onClick={() => setFiltroRama(null)}
              aria-label={`Quitar filtro por ${filtroRama.nombrePuesto}`}
            >
              ×
            </button>
          </div>
        )}

        <div className="banda-metricas">
          <div className="metrica">
            <span className="etiqueta-metrica">Total</span>
            <strong>{metricas.total}</strong>
          </div>
          <div className="metrica">
            <span className="etiqueta-metrica">
              <span className="punto punto--exito" aria-hidden="true" />
              Vigentes
            </span>
            <strong>{metricas.vigentes}</strong>
          </div>
          <div className="metrica">
            <span className="etiqueta-metrica">Terminadas</span>
            <strong>{metricas.terminadas}</strong>
          </div>
        </div>

        <div className="barra-filtros">
          <div className="campo-con-icono">
            <Search size={16} className="icono-campo" aria-hidden="true" />
            <input
              type="search"
              placeholder="Buscar por persona o puesto"
              value={busqueda}
              onChange={(evento) => setBusqueda(evento.target.value)}
              aria-label="Buscar por persona o puesto"
            />
          </div>
          <div className="grupo-filtros-secundarios">
            <select
              value={filtroEstado}
              onChange={(evento) => setFiltroEstado(evento.target.value)}
              aria-label="Filtrar por estado"
            >
              <option value="">Estado: Todas</option>
              <option value="vigente">Vigentes</option>
              <option value="terminada">Terminadas</option>
            </select>
            <Input
              id="filtro-vigente-desde"
              label="Vigente desde"
              type="date"
              value={filtroDesde}
              onChange={(evento) => setFiltroDesde(evento.target.value)}
            />
            <Input
              id="filtro-vigente-hasta"
              label="Vigente hasta"
              type="date"
              value={filtroHasta}
              onChange={(evento) => setFiltroHasta(evento.target.value)}
            />
            <select
              value={orden}
              onChange={(evento) => setOrden(evento.target.value as "desc" | "asc")}
              aria-label="Ordenar por fecha"
            >
              <option value="desc">Más recientes primero</option>
              <option value="asc">Más antiguas primero</option>
            </select>
          </div>
        </div>

        {estadoCarga === "cargando" && (
          <p className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando asignaciones…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar el listado de asignaciones
            </strong>
            <p>Ocurrió un problema al consultar el historial.</p>
            <button type="button" onClick={cargar}>
              Reintentar
            </button>
          </div>
        )}

        {estadoCarga === "listo" && filtradas.length === 0 && (
          <div className="estado-vacio">
            <Users size={28} aria-hidden="true" />
            <p>No hay asignaciones registradas o tu cuenta no tiene acceso al historial.</p>
          </div>
        )}

        {estadoCarga === "listo" && filtradas.length > 0 && (
            <div className="linea-tiempo">
              {[...agrupadasPorAnio.entries()].map(([anio, items]) => (
                <div key={anio} className="grupo-anio">
                  <h2 className="titulo-anio">{anio}</h2>
                  {items.map((asignacion) => (
                    <article key={asignacion.id} className="tarjeta-movimiento">
                      <div className="fila-movimiento">
                        <time dateTime={asignacion.vigente_desde}>
                          {formatearFecha(asignacion.vigente_desde)}
                          {" — "}
                          {asignacion.vigente_hasta ? formatearFecha(asignacion.vigente_hasta) : "Vigente"}
                        </time>
                        <Badge variante={asignacion.vigente_hasta ? "neutra" : "exito"}>
                          {asignacion.vigente_hasta ? "Terminada" : "Vigente"}
                        </Badge>
                      </div>
                      <p className="persona-celda" style={{ fontWeight: 600 }}>
                        <span className="avatar-iniciales">{inicialesDe(asignacion.persona_nombre)}</span>
                        {asignacion.persona_nombre}
                        <ArrowRight size={14} aria-hidden="true" />
                        {asignacion.nombre_puesto}
                      </p>
                      <p className="ayuda-campo">
                        {asignacion.nombre_departamento} · {asignacion.nombre_area}
                      </p>
                      {!asignacion.vigente_hasta && (
                        <div className="botonera" style={{ justifyContent: "flex-start", marginTop: "0.6rem" }}>
                          <a href={`/estructura/asignaciones/${asignacion.id}/terminar`}>Terminar</a>
                          <Button
                            href={`/estructura/asignaciones/${asignacion.id}/cambiar-puesto`}
                            variante="primario"
                            icono={Repeat}
                            posicionIcono="izquierda"
                            tamanoIcono={14}
                          >
                            Cambiar de puesto
                          </Button>
                        </div>
                      )}
                    </article>
                  ))}
                </div>
              ))}
            </div>
        )}
        </div>
        )}
      </div>
    </AppShell>
  );
}
