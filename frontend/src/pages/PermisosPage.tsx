import { useEffect, useMemo, useState } from "react";
import { AlertCircle, ArrowRight, Info, Loader2, Plus, Search, ShieldCheck } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { Badge } from "../components/Badge";
import { Input } from "../components/Input";

type TipoMovimientoPermiso = "otorgado" | "revocado";

type MovimientoPermiso = {
  id: string;
  puesto_id: string;
  nombre_puesto: string;
  codigo: string;
  tipo_movimiento: TipoMovimientoPermiso;
  fecha_efectiva: string;
  motivo: string | null;
  registrado_por_nombre: string | null;
  creado_en: string;
};

type Permiso = {
  codigo: string;
  heredable: boolean;
  activo: boolean;
};

type EstadoCarga = "cargando" | "listo" | "error";

const ETIQUETA_TIPO: Record<TipoMovimientoPermiso, string> = {
  otorgado: "Otorgado",
  revocado: "Revocado",
};

const VARIANTE_TIPO: Record<TipoMovimientoPermiso, "exito" | "neutra"> = {
  otorgado: "exito",
  revocado: "neutra",
};

function normalizar(texto: string): string {
  return texto
    .normalize("NFD")
    .replace(new RegExp("[\\u0300-\\u036f]", "g"), "")
    .toLowerCase();
}

function formatearFechaHora(fecha: string): string {
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

export function PermisosPage() {
  const [movimientos, setMovimientos] = useState<MovimientoPermiso[]>([]);
  const [catalogo, setCatalogo] = useState<Permiso[]>([]);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [busqueda, setBusqueda] = useState("");
  const [filtroTipo, setFiltroTipo] = useState("");
  const [filtroDesde, setFiltroDesde] = useState("");
  const [filtroHasta, setFiltroHasta] = useState("");
  const [orden, setOrden] = useState<"desc" | "asc">("desc");
  const [busquedaCatalogo, setBusquedaCatalogo] = useState("");
  const [filtroHeredable, setFiltroHeredable] = useState("");

  function cargar() {
    setEstadoCarga("cargando");
    Promise.all([
      apiFetch("/api/permisos/otorgados").then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      }),
      apiFetch("/api/permisos").then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      }),
    ])
      .then(([datosMovimientos, datosCatalogo]: [MovimientoPermiso[], Permiso[]]) => {
        setMovimientos(datosMovimientos);
        setCatalogo(datosCatalogo);
        setEstadoCarga("listo");
      })
      .catch(() => setEstadoCarga("error"));
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const metricas = useMemo(
    () => ({
      total: movimientos.length,
      otorgamientos: movimientos.filter((m) => m.tipo_movimiento === "otorgado").length,
      revocaciones: movimientos.filter((m) => m.tipo_movimiento === "revocado").length,
    }),
    [movimientos],
  );

  const filtrados = useMemo(() => {
    const consulta = normalizar(busqueda.trim());
    const desde = filtroDesde ? new Date(`${filtroDesde}T00:00:00`) : null;
    const hasta = filtroHasta ? new Date(`${filtroHasta}T00:00:00`) : null;
    const direccion = orden === "desc" ? -1 : 1;
    return [...movimientos]
      .sort(
        (a, b) =>
          direccion * (new Date(a.fecha_efectiva).getTime() - new Date(b.fecha_efectiva).getTime()),
      )
      .filter((m) => {
        const coincideBusqueda =
          !consulta || normalizar(m.nombre_puesto).includes(consulta) || normalizar(m.codigo).includes(consulta);
        const coincideTipo = !filtroTipo || m.tipo_movimiento === filtroTipo;
        const fechaEfectiva = new Date(m.fecha_efectiva);
        const coincideDesde = !desde || fechaEfectiva >= desde;
        const coincideHasta = !hasta || fechaEfectiva <= hasta;
        return coincideBusqueda && coincideTipo && coincideDesde && coincideHasta;
      });
  }, [movimientos, busqueda, filtroTipo, filtroDesde, filtroHasta, orden]);

  const catalogoFiltrado = useMemo(() => {
    const consulta = normalizar(busquedaCatalogo.trim());
    return catalogo.filter((permiso) => {
      const coincideBusqueda = !consulta || normalizar(permiso.codigo).includes(consulta);
      const coincideHeredable =
        !filtroHeredable || (filtroHeredable === "si" ? permiso.heredable : !permiso.heredable);
      return coincideBusqueda && coincideHeredable;
    });
  }, [catalogo, busquedaCatalogo, filtroHeredable]);

  const agrupadosPorAnio = useMemo(() => {
    const grupos = new Map<string, MovimientoPermiso[]>();
    for (const movimiento of filtrados) {
      const anio = new Date(movimiento.fecha_efectiva).getFullYear().toString();
      const lista = grupos.get(anio) ?? [];
      lista.push(movimiento);
      grupos.set(anio, lista);
    }
    return grupos;
  }, [filtrados]);

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          Estructura organizacional › <strong>Permisos</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Permisos</h1>
            <p className="subtitulo-pagina">Historial de permisos otorgados o revocados a cada puesto.</p>
          </div>
          <Button href="/estructura/permisos/otorgar" variante="primario" icono={Plus} posicionIcono="izquierda">
            Otorgar permiso
          </Button>
        </div>

        <p className="tarjeta-info">
          <Info size={16} aria-hidden="true" />
          Para revocar un permiso, abre la ficha del puesto correspondiente en{" "}
          <a href="/estructura/puestos">Estructura organizacional → Puestos</a>.
        </p>

        <div className="banda-metricas">
          <div className="metrica">
            <span className="etiqueta-metrica">Total</span>
            <strong>{metricas.total}</strong>
          </div>
          <div className="metrica">
            <span className="etiqueta-metrica">
              <span className="punto punto--exito" aria-hidden="true" />
              Otorgamientos
            </span>
            <strong>{metricas.otorgamientos}</strong>
          </div>
          <div className="metrica">
            <span className="etiqueta-metrica">Revocaciones</span>
            <strong>{metricas.revocaciones}</strong>
          </div>
        </div>

        {estadoCarga === "cargando" && (
          <p className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando permisos…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar el historial de permisos
            </strong>
            <p>Ocurrió un problema al consultar el historial.</p>
            <button type="button" onClick={cargar}>
              Reintentar
            </button>
          </div>
        )}

        {estadoCarga === "listo" && (
          <Card>
            <h3>Catálogo de permisos</h3>
            <div className="barra-filtros">
              <div className="campo-con-icono">
                <Search size={16} className="icono-campo" aria-hidden="true" />
                <input
                  type="search"
                  placeholder="Buscar por código de permiso"
                  value={busquedaCatalogo}
                  onChange={(evento) => setBusquedaCatalogo(evento.target.value)}
                  aria-label="Buscar por código de permiso"
                />
              </div>
              <select
                value={filtroHeredable}
                onChange={(evento) => setFiltroHeredable(evento.target.value)}
                aria-label="Filtrar por herencia"
              >
                <option value="">Tipo: Todos</option>
                <option value="si">Heredable</option>
                <option value="no">No heredable</option>
              </select>
            </div>
            {catalogoFiltrado.length === 0 ? (
              <p>No hay permisos que coincidan con la búsqueda.</p>
            ) : (
              <ul className="leyenda-estados leyenda-estados--grilla lista-desplazable">
                {catalogoFiltrado.map((permiso) => (
                  <li key={permiso.codigo}>
                    <span
                      className={`punto ${permiso.heredable ? "punto--exito" : "punto--peligro"}`}
                      aria-hidden="true"
                    />
                    <span>
                      <strong>{permiso.codigo}</strong>
                      <span className="descripcion">
                        {permiso.heredable
                          ? "Heredable — sube por reporta_a_id"
                          : "No heredable — sólo el puesto que lo tiene"}
                      </span>
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </Card>
        )}

        {estadoCarga === "listo" && (
          <div className="barra-filtros">
            <div className="campo-con-icono">
              <ShieldCheck size={16} className="icono-campo" aria-hidden="true" />
              <input
                type="search"
                placeholder="Buscar por puesto o código de permiso"
                value={busqueda}
                onChange={(evento) => setBusqueda(evento.target.value)}
                aria-label="Buscar por puesto o código de permiso"
              />
            </div>
            <select
              value={filtroTipo}
              onChange={(evento) => setFiltroTipo(evento.target.value)}
              aria-label="Filtrar por tipo de movimiento"
            >
              <option value="">Tipo: Todos</option>
              <option value="otorgado">Otorgado</option>
              <option value="revocado">Revocado</option>
            </select>
          </div>
        )}

        {estadoCarga === "listo" && (
          <div className="layout-bitacora">
            <div className="linea-tiempo bloque-desplazable">
              {filtrados.length === 0 ? (
                <div className="estado-vacio">
                  <ShieldCheck size={28} aria-hidden="true" />
                  <p>No hay movimientos de permisos registrados o tu cuenta no tiene acceso al historial.</p>
                </div>
              ) : (
                [...agrupadosPorAnio.entries()].map(([anio, items]) => (
                  <div key={anio} className="grupo-anio">
                    <h2 className="titulo-anio">{anio}</h2>
                    {items.map((movimiento) => (
                      <article key={movimiento.id} className="tarjeta-movimiento">
                        <div className="fila-movimiento">
                          <time dateTime={movimiento.fecha_efectiva}>
                            {formatearFechaHora(movimiento.fecha_efectiva)}
                          </time>
                          <Badge variante={VARIANTE_TIPO[movimiento.tipo_movimiento]}>
                            {ETIQUETA_TIPO[movimiento.tipo_movimiento]}
                          </Badge>
                        </div>
                        <p style={{ fontWeight: 600, margin: 0, display: "flex", alignItems: "center", gap: "0.5rem" }}>
                          {movimiento.nombre_puesto}
                          <ArrowRight size={14} aria-hidden="true" />
                          {movimiento.codigo}
                        </p>
                        {movimiento.motivo && <p>{movimiento.motivo}</p>}
                        <p className="autor-movimiento">
                          <strong>{movimiento.registrado_por_nombre ?? "Sistema"}</strong>
                        </p>
                      </article>
                    ))}
                  </div>
                ))
              )}
            </div>

            <aside>
              <Card>
                <h3>Resumen</h3>
                <div className="rejilla-resumen">
                  <div>
                    <strong>{metricas.total}</strong>
                    <span>Movimientos registrados</span>
                  </div>
                  <div>
                    <strong>{metricas.otorgamientos}</strong>
                    <span>Otorgamientos</span>
                  </div>
                </div>
                <p className="etiqueta-metrica" style={{ marginTop: "1.25rem", marginBottom: "0.5rem" }}>
                  Ordenar y filtrar por fecha
                </p>
                <div className="grupo-filtros-secundarios grupo-filtros-secundarios--apilado">
                  <Input
                    id="filtro-fecha-efectiva-desde"
                    label="Desde"
                    type="date"
                    value={filtroDesde}
                    onChange={(evento) => setFiltroDesde(evento.target.value)}
                  />
                  <Input
                    id="filtro-fecha-efectiva-hasta"
                    label="Hasta"
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
              </Card>
            </aside>
          </div>
        )}
      </div>
    </AppShell>
  );
}
