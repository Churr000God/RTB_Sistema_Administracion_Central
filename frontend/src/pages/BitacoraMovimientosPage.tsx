import { useEffect, useMemo, useState } from "react";
import { useParams } from "react-router-dom";
import { ArrowRight, Loader2, Lock, Search } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { derivarTransiciones, resumenBitacora, type Estado, type Movimiento } from "../lib/movimientos";

type Persona = {
  id: string;
  primer_nombre: string;
  apellido_paterno: string;
  estado: string;
};

type EstadoCarga = "cargando" | "listo" | "error";

const ETIQUETA_ESTADO: Record<Estado, string> = {
  activo: "Activo",
  suspension: "Suspendido",
  baja_definitiva: "Baja",
};

const CLASE_ESTADO: Record<Estado, string> = {
  activo: "insignia--exito",
  suspension: "insignia--aviso",
  baja_definitiva: "insignia--peligro",
};

const ETIQUETA_TIPO: Record<string, string> = {
  alta: "Alta",
  suspension: "Suspensión",
  reactivacion: "Reactivación",
  baja_definitiva: "Baja definitiva",
};

function formatearFecha(fecha: string): string {
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" });
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

export function BitacoraMovimientosPage() {
  const { id } = useParams<{ id: string }>();
  const [persona, setPersona] = useState<Persona | null>(null);
  const [movimientos, setMovimientos] = useState<Movimiento[]>([]);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [busqueda, setBusqueda] = useState("");
  const [filtroTipo, setFiltroTipo] = useState("");

  useEffect(() => {
    setEstadoCarga("cargando");
    Promise.all([
      apiFetch(`/api/personas/${id}`).then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      }),
      apiFetch(`/api/personas/${id}/movimientos`).then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      }),
    ])
      .then(([p, m]) => {
        setPersona(p);
        setMovimientos(m);
        setEstadoCarga("listo");
      })
      .catch(() => setEstadoCarga("error"));
  }, [id]);

  const transiciones = useMemo(() => derivarTransiciones(movimientos), [movimientos]);
  const resumen = useMemo(() => resumenBitacora(movimientos), [movimientos]);
  const primerRegistro = transiciones[0] ?? null;
  const ultimoRegistro = transiciones[transiciones.length - 1] ?? null;

  const filtradas = useMemo(() => {
    const consulta = busqueda.trim().toLowerCase();
    return [...transiciones]
      .reverse()
      .filter((t) => {
        const coincideBusqueda =
          !consulta ||
          (t.motivo ?? "").toLowerCase().includes(consulta) ||
          (t.registrado_por_nombre ?? "").toLowerCase().includes(consulta);
        const coincideTipo = !filtroTipo || t.tipo_movimiento === filtroTipo;
        return coincideBusqueda && coincideTipo;
      });
  }, [transiciones, busqueda, filtroTipo]);

  const agrupadasPorAnio = useMemo(() => {
    const grupos = new Map<string, typeof filtradas>();
    for (const transicion of filtradas) {
      const anio = new Date(transicion.fecha_efectiva).getFullYear().toString();
      const lista = grupos.get(anio) ?? [];
      lista.push(transicion);
      grupos.set(anio, lista);
    }
    return grupos;
  }, [filtradas]);

  const nombreCompleto = persona ? `${persona.primer_nombre} ${persona.apellido_paterno}` : "";
  const iniciales = persona
    ? `${persona.primer_nombre[0] ?? ""}${persona.apellido_paterno[0] ?? ""}`.toUpperCase()
    : "";

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <a href="/personas">Personas</a>
          {persona && (
            <>
              {" / "}
              <a href={`/personas/${id}`}>{nombreCompleto}</a>
            </>
          )}
          {" / "}
          <strong>Bitácora de movimientos</strong>
        </nav>
        <h1>Bitácora de movimientos</h1>
        <p className="subtitulo-pagina">
          Historial cronológico de los cambios de estado de la persona. Cada registro conserva
          quién lo ejecutó y el motivo declarado.
        </p>

        {estadoCarga === "cargando" && (
          <p className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando bitácora…
          </p>
        )}

        {estadoCarga === "error" && (
          <p role="alert">No se pudo cargar la bitácora de esta persona.</p>
        )}

        {estadoCarga === "listo" && persona && (
          <div className="cabecera-persona cabecera-bitacora">
            <div className="identidad">
              <span className="avatar-iniciales">{iniciales}</span>
              <strong>{nombreCompleto}</strong>
            </div>
            <div className="metricas-cabecera">
              <div>
                <span className="etiqueta-metrica">Movimientos</span>
                <strong>{resumen.total}</strong>
              </div>
              {ultimoRegistro && (
                <div>
                  <span className="etiqueta-metrica">Última actualización</span>
                  <strong>{formatearFecha(ultimoRegistro.fecha_efectiva)}</strong>
                </div>
              )}
            </div>
            <span className={`insignia ${CLASE_ESTADO[persona.estado as Estado] ?? "insignia--neutra"}`}>
              {ETIQUETA_ESTADO[persona.estado as Estado] ?? persona.estado}
            </span>
          </div>
        )}

        {estadoCarga === "listo" && (
          <>
            <div className="barra-filtros">
              <div className="campo-con-icono">
                <Search size={16} className="icono-campo" aria-hidden="true" />
                <input
                  type="search"
                  placeholder="Buscar por motivo o autor"
                  value={busqueda}
                  onChange={(evento) => setBusqueda(evento.target.value)}
                  aria-label="Buscar por motivo o autor"
                />
              </div>
              <select
                value={filtroTipo}
                onChange={(evento) => setFiltroTipo(evento.target.value)}
                aria-label="Filtrar por tipo de movimiento"
              >
                <option value="">Todos los tipos</option>
                <option value="alta">Alta</option>
                <option value="suspension">Suspensión</option>
                <option value="reactivacion">Reactivación</option>
                <option value="baja_definitiva">Baja definitiva</option>
              </select>
            </div>

            {filtradas.length === 0 && <p>No hay movimientos que coincidan con el filtro.</p>}

            {filtradas.length > 0 && (
              <div className="layout-bitacora">
                <div className="linea-tiempo">
                  {[...agrupadasPorAnio.entries()].map(([anio, items]) => (
                    <div key={anio} className="grupo-anio">
                      <h2 className="titulo-anio">{anio}</h2>
                      {items.map((transicion) => (
                        <article key={transicion.id} className="tarjeta-movimiento">
                          <div className="fila-movimiento">
                            <time dateTime={transicion.fecha_efectiva}>
                              {formatearFechaHora(transicion.fecha_efectiva)}
                            </time>
                            <div className="pildora-transicion">
                              {transicion.estadoAnterior && (
                                <>
                                  <span className={`insignia ${CLASE_ESTADO[transicion.estadoAnterior]}`}>
                                    {ETIQUETA_ESTADO[transicion.estadoAnterior]}
                                  </span>
                                  <ArrowRight size={14} aria-hidden="true" />
                                </>
                              )}
                              <span className={`insignia ${CLASE_ESTADO[transicion.estadoNuevo]}`}>
                                {ETIQUETA_ESTADO[transicion.estadoNuevo]}
                              </span>
                            </div>
                          </div>
                          {transicion.motivo && <p>{transicion.motivo}</p>}
                          {transicion.documento_ref && (
                            <p className="ayuda-campo">Documento: {transicion.documento_ref}</p>
                          )}
                          <p className="autor-movimiento">
                            <strong>{transicion.registrado_por_nombre ?? "Sistema"}</strong>
                            {" · "}
                            {ETIQUETA_TIPO[transicion.tipo_movimiento] ?? transicion.tipo_movimiento}
                          </p>
                        </article>
                      ))}
                    </div>
                  ))}
                </div>

                <aside>
                  <div className="tarjeta-resumen">
                    <h3>Resumen</h3>
                    <div className="rejilla-resumen">
                      <div>
                        <strong>{resumen.total}</strong>
                        <span>Movimientos registrados</span>
                      </div>
                      <div>
                        <strong>{resumen.diasEnSuspension}</strong>
                        <span>Días en suspensión</span>
                      </div>
                      <div>
                        <strong>{resumen.conteos.suspension}</strong>
                        <span>Suspensiones</span>
                      </div>
                      <div>
                        <strong>{resumen.conteos.reactivacion}</strong>
                        <span>Reactivaciones</span>
                      </div>
                    </div>
                    {primerRegistro && (
                      <p className="primer-registro">
                        Primer registro: {formatearFecha(primerRegistro.fecha_efectiva)}
                      </p>
                    )}
                  </div>

                  <div className="tarjeta-resumen">
                    <h3>Estados</h3>
                    <ul className="leyenda-estados">
                      <li>
                        <span className="punto punto--exito" aria-hidden="true" />
                        <span>
                          <strong>Activo</strong>
                          <span className="descripcion">Captura y valida jornada con normalidad.</span>
                        </span>
                      </li>
                      <li>
                        <span className="punto punto--aviso" aria-hidden="true" />
                        <span>
                          <strong>Suspendido</strong>
                          <span className="descripcion">Conserva el registro; no genera obligación de marcar.</span>
                        </span>
                      </li>
                      <li>
                        <span className="punto punto--peligro" aria-hidden="true" />
                        <span>
                          <strong>Baja</strong>
                          <span className="descripcion">Cierra el expediente; el historial se conserva.</span>
                        </span>
                      </li>
                    </ul>
                  </div>

                  <div className="tarjeta-resumen tarjeta-inmutable">
                    <h3>
                      <Lock size={16} aria-hidden="true" />
                      Registro inmutable
                    </h3>
                    <p>
                      Los movimientos no se editan ni se borran. Una corrección se registra como
                      un movimiento nuevo que referencia al anterior.
                    </p>
                  </div>
                </aside>
              </div>
            )}
          </>
        )}
      </div>
    </AppShell>
  );
}
