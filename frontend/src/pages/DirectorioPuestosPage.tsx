import { useEffect, useMemo, useState } from "react";
import { AlertCircle, Building2, Loader2, Plus, Search } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Badge } from "../components/Badge";
import {
  construirBosque,
  descendientesIncluidoSiMismo,
  filtrarBosque,
  Organigrama,
  type PuestoOrganigrama,
} from "../components/Organigrama";

type Puesto = {
  id: string;
  departamento_id: string;
  nombre_puesto: string;
  nivel: string;
  plazas_totales: number;
  reporta_a_id: string | null;
  activo: boolean;
  creado_en: string;
  actualizado_en: string;
};

type Departamento = {
  id: string;
  nombre_departamento: string;
};

type Asignacion = {
  puesto_id: string;
  vigente_hasta: string | null;
};

type EstadoCarga = "cargando" | "listo" | "error";
type EstadoCatalogo = "cargando" | "listo" | "error" | "sin_permiso";
type FiltroRama = { puestoId: string; nombrePuesto: string };

const ETIQUETA_NIVEL: Record<string, string> = {
  direccion: "Dirección",
  gerencia: "Gerencia",
  mando_medio: "Mando medio",
  operativo: "Operativo",
};

function normalizar(texto: string): string {
  return texto
    .normalize("NFD")
    .replace(new RegExp("[\\u0300-\\u036f]", "g"), "")
    .toLowerCase();
}

export function DirectorioPuestosPage() {
  const [puestos, setPuestos] = useState<Puesto[]>([]);
  const [nombresDepartamento, setNombresDepartamento] = useState<Record<string, string>>({});
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [busqueda, setBusqueda] = useState("");
  const [filtroEstado, setFiltroEstado] = useState("");
  const [vista, setVista] = useState<"tabla" | "organigrama">("tabla");
  const [busquedaOrganigrama, setBusquedaOrganigrama] = useState("");
  const [filtroRama, setFiltroRama] = useState<FiltroRama | null>(null);
  const [asignaciones, setAsignaciones] = useState<Asignacion[]>([]);
  const [estadoAsignaciones, setEstadoAsignaciones] = useState<EstadoCatalogo>("cargando");

  function cargar() {
    setEstadoCarga("cargando");
    Promise.all([
      apiFetch("/api/puestos").then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      }),
      apiFetch("/api/departamentos").then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      }),
    ])
      .then(([datosPuestos, datosDepartamentos]: [Puesto[], Departamento[]]) => {
        setPuestos(datosPuestos);
        setNombresDepartamento(
          Object.fromEntries(datosDepartamentos.map((d) => [d.id, d.nombre_departamento])),
        );
        setEstadoCarga("listo");
      })
      .catch(() => setEstadoCarga("error"));

    // Gate propio (asignacion_lectura/edicion) — sólo alimenta el conteo de "ocupadas" del
    // organigrama, el árbol en sí ya sale de /api/puestos de arriba. Si esto falla, el
    // organigrama degrada solo a mostrar el total de plazas (ver Organigrama.tsx).
    setEstadoAsignaciones("cargando");
    apiFetch("/api/asignaciones")
      .then((r) => {
        if (r.status === 403) throw new Error("sin_permiso");
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      })
      .then((datos: Asignacion[]) => {
        setAsignaciones(datos);
        setEstadoAsignaciones("listo");
      })
      .catch((e: Error) => setEstadoAsignaciones(e.message === "sin_permiso" ? "sin_permiso" : "error"));
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const ocupadasPorPuesto = useMemo(() => {
    if (estadoAsignaciones !== "listo") return undefined;
    const conteo: Record<string, number> = {};
    for (const a of asignaciones) {
      if (a.vigente_hasta) continue;
      conteo[a.puesto_id] = (conteo[a.puesto_id] ?? 0) + 1;
    }
    return conteo;
  }, [asignaciones, estadoAsignaciones]);

  const bosque = useMemo(() => construirBosque(puestos), [puestos]);
  const bosqueFiltrado = useMemo(
    () => filtrarBosque(bosque, busquedaOrganigrama.trim().toLowerCase()),
    [bosque, busquedaOrganigrama],
  );

  function handleSeleccionarPuesto(puesto: PuestoOrganigrama) {
    setFiltroRama({ puestoId: puesto.id, nombrePuesto: puesto.nombre_puesto });
    setVista("tabla");
  }

  // Autorreferencial: el propio listado de /api/puestos ya tiene todo lo necesario para
  // resolver "reporta a" — no hace falta un fetch aparte.
  const nombresPuesto = useMemo(
    () => Object.fromEntries(puestos.map((p) => [p.id, p.nombre_puesto])),
    [puestos],
  );

  const metricas = useMemo(
    () => ({
      total: puestos.length,
      activos: puestos.filter((p) => p.activo).length,
      inactivos: puestos.filter((p) => !p.activo).length,
    }),
    [puestos],
  );

  const ramaFiltrada = useMemo(
    () => (filtroRama ? descendientesIncluidoSiMismo(puestos, filtroRama.puestoId) : null),
    [puestos, filtroRama],
  );

  const filtrados = useMemo(() => {
    const consulta = normalizar(busqueda.trim());
    return puestos.filter((puesto) => {
      const coincideBusqueda = !consulta || normalizar(puesto.nombre_puesto).includes(consulta);
      const coincideEstado =
        !filtroEstado || (filtroEstado === "activo" ? puesto.activo : !puesto.activo);
      const coincideRama = !ramaFiltrada || ramaFiltrada.has(puesto.id);
      return coincideBusqueda && coincideEstado && coincideRama;
    });
  }, [puestos, busqueda, filtroEstado, ramaFiltrada]);

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          Estructura organizacional › <strong>Puestos</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Puestos</h1>
            <p className="subtitulo-pagina">Catálogo de puestos por departamento.</p>
          </div>
          <Button href="/estructura/puestos/nueva" variante="primario" icono={Plus} posicionIcono="izquierda">
            Nuevo puesto
          </Button>
        </div>

        <div className="pestanas" role="tablist" aria-label="Vista de puestos">
          <button
            type="button"
            role="tab"
            aria-selected={vista === "tabla"}
            className={`pestana${vista === "tabla" ? " pestana--activa" : ""}`}
            onClick={() => setVista("tabla")}
          >
            Catálogo
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

        {vista === "organigrama" && estadoCarga === "listo" && (
          <div role="tabpanel">
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
              Activos
            </span>
            <strong>{metricas.activos}</strong>
          </div>
          <div className="metrica">
            <span className="etiqueta-metrica">
              <span className="punto punto--peligro" aria-hidden="true" />
              Inactivos
            </span>
            <strong>{metricas.inactivos}</strong>
          </div>
        </div>

        <div className="barra-filtros">
          <div className="campo-con-icono">
            <Search size={16} className="icono-campo" aria-hidden="true" />
            <input
              type="search"
              placeholder="Buscar por nombre"
              value={busqueda}
              onChange={(evento) => setBusqueda(evento.target.value)}
              aria-label="Buscar por nombre"
            />
          </div>
          <select
            value={filtroEstado}
            onChange={(evento) => setFiltroEstado(evento.target.value)}
            aria-label="Filtrar por estado"
          >
            <option value="">Estado: Todos</option>
            <option value="activo">Activo</option>
            <option value="inactivo">Inactivo</option>
          </select>
        </div>

        {estadoCarga === "cargando" && (
          <p className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando puestos…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar el listado de puestos
            </strong>
            <p>Ocurrió un problema al consultar el catálogo.</p>
            <button type="button" onClick={cargar}>
              Reintentar
            </button>
          </div>
        )}

        {estadoCarga === "listo" && filtrados.length === 0 && (
          <div className="estado-vacio">
            <Building2 size={28} aria-hidden="true" />
            <p>No hay puestos registrados o tu cuenta no tiene acceso al catálogo.</p>
          </div>
        )}

        {estadoCarga === "listo" && filtrados.length > 0 && (
          <>
            <div className="tabla-desplazable">
              <table>
                <thead>
                  <tr>
                    <th>Nombre</th>
                    <th>Departamento</th>
                    <th>Nivel</th>
                    <th>Reporta a</th>
                    <th>Plazas</th>
                    <th>Estado</th>
                  </tr>
                </thead>
                <tbody>
                  {filtrados.map((puesto) => (
                    <tr key={puesto.id}>
                      <td>
                        <a href={`/estructura/puestos/${puesto.id}`} style={{ fontWeight: 600 }}>
                          {puesto.nombre_puesto}
                        </a>
                      </td>
                      <td>{nombresDepartamento[puesto.departamento_id] ?? "—"}</td>
                      <td>{ETIQUETA_NIVEL[puesto.nivel] ?? puesto.nivel}</td>
                      <td>{puesto.reporta_a_id ? nombresPuesto[puesto.reporta_a_id] ?? "—" : "—"}</td>
                      <td>{puesto.plazas_totales}</td>
                      <td>
                        <Badge variante={puesto.activo ? "exito" : "peligro"}>
                          {puesto.activo ? "Activo" : "Inactivo"}
                        </Badge>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="pie-tabla">
              Mostrando {filtrados.length} de {puestos.length} puestos
            </p>
          </>
        )}
        </div>
        )}
      </div>
    </AppShell>
  );
}
