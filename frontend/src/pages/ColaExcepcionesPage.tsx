import { useEffect, useMemo, useState } from "react";
import { AlertCircle, Eye, Loader2, Lock, Search, Trash2, Wrench } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { formatearFechaCorta, formatearHoraMexico } from "../lib/calendario";
import { hrefRevisarDia } from "../lib/enlacesDias";
import { consultarSesion } from "../lib/sesion";
import { etiquetaMotivo } from "../lib/motivosRevision";
import { AppShell } from "../layouts/AppShell";
import { Badge } from "../components/Badge";
import { DescartarMarcaTardiaModal } from "../components/DescartarMarcaTardiaModal";
import { Button } from "../components/Button";
import { Input } from "../components/Input";

type Excepcion = {
  id: number;
  motivo_revision: string;
  estado: "pendiente" | "resuelto";
  creado_en: string;
  marca_id: number | null;
  dia_id: number | null;
  persona_id?: string | null;
  persona_nombre: string | null;
  momento_dispositivo: string | null;
  // Sólo las de motivo dia_cerrado (86_*.sql); ausentes/false/null en el resto.
  es_dia_cerrado?: boolean;
  dia_de_la_marca_id?: number | null;
  dia_de_la_marca_fecha?: string | null;
  dia_de_la_marca_estado?: "abierto" | "bloqueado" | "cerrado" | "revisado" | null;
  camino_resolucion?: "revisar_dia" | "descartar" | null;
};

type Tipo = "todas" | "dia_cerrado";

// Mismas etiquetas/variantes que la pantalla de Días para el estado del día.
const ETIQUETA_ESTADO_DIA: Record<string, string> = {
  abierto: "Abierto",
  cerrado: "Cerrado",
  bloqueado: "Bloqueado — necesita revisión",
  revisado: "Revisado",
};
const VARIANTE_ESTADO_DIA: Record<string, "neutra" | "peligro" | "exito"> = {
  abierto: "neutra",
  cerrado: "neutra",
  bloqueado: "peligro",
  revisado: "exito",
};

type EstadoCarga = "cargando" | "listo" | "error";

type Orden = "fecha_desc" | "fecha_asc" | "motivo_asc" | "persona_asc";

function normalizar(texto: string): string {
  return texto
    .normalize("NFD")
    .replace(new RegExp("[\\u0300-\\u036f]", "g"), "")
    .toLowerCase();
}

function formatearFechaHora(fecha: string | null): string {
  if (!fecha) return "—";
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "—";
  return formatearHoraMexico(valor, {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function ColaExcepcionesPage() {
  const [excepciones, setExcepciones] = useState<Excepcion[]>([]);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [busqueda, setBusqueda] = useState("");
  const [filtroMotivo, setFiltroMotivo] = useState("");
  const [filtroDesde, setFiltroDesde] = useState("");
  const [filtroHasta, setFiltroHasta] = useState("");
  const [orden, setOrden] = useState<Orden>("fecha_desc");
  const [tipo, setTipo] = useState<Tipo>("todas");
  // Sólo comodidad de UI (la base decide en fn_excepcion_dia_cerrado_descartar): sin sesión
  // legible se trata como "sin permiso" y no se ofrece una acción que daría 403.
  const [puedeDescartar, setPuedeDescartar] = useState(false);
  const [aDescartar, setADescartar] = useState<Excepcion | null>(null);

  function cargar() {
    setEstadoCarga("cargando");
    apiFetch("/api/excepciones")
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datos: Excepcion[]) => {
        // El servidor ya filtra a estado='pendiente'. Se muestran todas -- incluidas las de
        // dia_id (paridad_impar, sin marca_id ni persona_nombre/momento_dispositivo resueltos
        // por el backend, ver ColaExcepcionesPage.test.tsx).
        setExcepciones(datos);
        setEstadoCarga("listo");
      })
      .catch(() => setEstadoCarga("error"));
  }

  useEffect(() => {
    cargar();
    consultarSesion()
      .then((sesion) => setPuedeDescartar(sesion.puede_descartar_excepciones === true))
      .catch(() => setPuedeDescartar(false));
  }, []);

  const totalDiaCerrado = useMemo(
    () => excepciones.filter((excepcion) => excepcion.es_dia_cerrado).length,
    [excepciones],
  );
  const visibles = useMemo(
    () => (tipo === "dia_cerrado" ? excepciones.filter((excepcion) => excepcion.es_dia_cerrado) : excepciones),
    [excepciones, tipo],
  );

  const porMotivo = useMemo(() => {
    const conteo = new Map<string, number>();
    for (const excepcion of visibles) {
      conteo.set(excepcion.motivo_revision, (conteo.get(excepcion.motivo_revision) ?? 0) + 1);
    }
    return conteo;
  }, [visibles]);

  const motivosPresentes = useMemo(
    () => [...porMotivo.keys()].sort((a, b) => a.localeCompare(b)),
    [porMotivo],
  );

  const filtradas = useMemo(() => {
    const consulta = normalizar(busqueda.trim());
    const desde = filtroDesde ? new Date(`${filtroDesde}T00:00:00`) : null;
    const hasta = filtroHasta ? new Date(`${filtroHasta}T23:59:59`) : null;

    const resultado = visibles.filter((excepcion) => {
      const coincideBusqueda = !consulta || normalizar(excepcion.persona_nombre ?? "").includes(consulta);
      const coincideMotivo = !filtroMotivo || excepcion.motivo_revision === filtroMotivo;
      const fechaDetectada = new Date(excepcion.creado_en);
      const coincideDesde = !desde || fechaDetectada >= desde;
      const coincideHasta = !hasta || fechaDetectada <= hasta;
      return coincideBusqueda && coincideMotivo && coincideDesde && coincideHasta;
    });

    return resultado.sort((a, b) => {
      switch (orden) {
        case "fecha_asc":
          return a.creado_en.localeCompare(b.creado_en);
        case "motivo_asc":
          return a.motivo_revision.localeCompare(b.motivo_revision);
        case "persona_asc":
          return (a.persona_nombre ?? "").localeCompare(b.persona_nombre ?? "");
        case "fecha_desc":
        default:
          return b.creado_en.localeCompare(a.creado_en);
      }
    });
  }, [visibles, busqueda, filtroMotivo, filtroDesde, filtroHasta, orden]);

  // Una excepción de día cerrado nunca se corrige: se resuelve revisando el día o descartando la
  // marca tardía (camino_resolucion lo decide el backend según el estado del día).
  function renderAccion(excepcion: Excepcion) {
    if (!excepcion.es_dia_cerrado) {
      return (
        <a href={`/tiempo/excepciones/${excepcion.id}/corregir`} className="boton-con-icono">
          <Wrench size={14} aria-hidden="true" />
          Corregir
        </a>
      );
    }
    if (excepcion.camino_resolucion === "revisar_dia") {
      return (
        <a
          href={hrefRevisarDia({
            diaId: excepcion.dia_de_la_marca_id,
            personaId: excepcion.persona_id,
            fecha: excepcion.dia_de_la_marca_fecha,
          })}
          className="boton-con-icono"
        >
          <Eye size={14} aria-hidden="true" />
          Revisar día
        </a>
      );
    }
    if (excepcion.camino_resolucion === "descartar") {
      if (!puedeDescartar) {
        return (
          <span className="sin-accion">
            <Lock size={14} aria-hidden="true" />
            Sin permiso para descartar. El día ya está revisado: sólo se puede descartar.
          </span>
        );
      }
      return (
        <Button className="boton-descartar" icono={Trash2} posicionIcono="izquierda" onClick={() => setADescartar(excepcion)}>
          Descartar marca tardía
        </Button>
      );
    }
    return "—";
  }

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <strong>Excepciones pendientes</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Excepciones pendientes</h1>
            <p className="subtitulo-pagina">
              Marcas apartadas para revisión — corrígelas para cerrar la excepción. Las de tipo{" "}
              <em>día cerrado</em> no se corrigen: se resuelven revisando el día o, si el día ya está
              revisado, descartando la marca tardía.
            </p>
          </div>
        </div>

        {estadoCarga === "listo" && (
          <div role="tablist" aria-label="Tipo de excepción" className="pestanas-tipo">
            <Button
              role="tab"
              aria-selected={tipo === "todas"}
              variante={tipo === "todas" ? "primario" : "plano"}
              onClick={() => setTipo("todas")}
            >
              {`Todas (${excepciones.length})`}
            </Button>
            <Button
              role="tab"
              aria-selected={tipo === "dia_cerrado"}
              variante={tipo === "dia_cerrado" ? "primario" : "plano"}
              onClick={() => setTipo("dia_cerrado")}
            >
              {`Día cerrado (${totalDiaCerrado})`}
            </Button>
          </div>
        )}

        {estadoCarga === "listo" && excepciones.length > 0 && (
          <div className="banda-metricas">
            <div className="metrica">
              <span className="etiqueta-metrica">
                <span className="punto punto--aviso" aria-hidden="true" />
                Pendientes
              </span>
              <strong>{visibles.length}</strong>
            </div>
            {[...porMotivo.entries()].map(([motivo, cantidad]) => (
              <div className="metrica" key={motivo}>
                <span className="etiqueta-metrica">{etiquetaMotivo(motivo)}</span>
                <strong>{cantidad}</strong>
              </div>
            ))}
          </div>
        )}

        {estadoCarga === "listo" && excepciones.length > 0 && (
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
              <select
                value={filtroMotivo}
                onChange={(evento) => setFiltroMotivo(evento.target.value)}
                aria-label="Filtrar por motivo"
              >
                <option value="">Motivo: Todos</option>
                {motivosPresentes.map((motivo) => (
                  <option key={motivo} value={motivo}>
                    {etiquetaMotivo(motivo)}
                  </option>
                ))}
              </select>
              <Input
                id="filtro-detectada-desde"
                label="Detectada desde"
                type="date"
                value={filtroDesde}
                onChange={(evento) => setFiltroDesde(evento.target.value)}
              />
              <Input
                id="filtro-detectada-hasta"
                label="Detectada hasta"
                type="date"
                value={filtroHasta}
                onChange={(evento) => setFiltroHasta(evento.target.value)}
              />
              <select
                value={orden}
                onChange={(evento) => setOrden(evento.target.value as Orden)}
                aria-label="Ordenar por"
              >
                <option value="fecha_desc">Detectada: más recientes primero</option>
                <option value="fecha_asc">Detectada: más antiguas primero</option>
                <option value="motivo_asc">Motivo (A-Z)</option>
                <option value="persona_asc">Persona (A-Z)</option>
              </select>
            </div>
          </div>
        )}

        {estadoCarga === "cargando" && (
          <p className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando excepciones…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar la cola de excepciones
            </strong>
            <p>Ocurrió un problema al consultar las excepciones pendientes.</p>
            <button type="button" onClick={cargar}>
              Reintentar
            </button>
          </div>
        )}

        {estadoCarga === "listo" && tipo === "todas" && excepciones.length === 0 && (
          <div className="estado-vacio">
            <p>No hay excepciones de marca pendientes.</p>
          </div>
        )}

        {estadoCarga === "listo" && tipo === "dia_cerrado" && visibles.length === 0 && (
          <div className="estado-vacio">
            <p>
              <strong>No hay excepciones de día cerrado pendientes.</strong>
              <br />
              Las marcas tardías de días ya cerrados aparecerán aquí hasta que se revise el día o se
              descarten.
            </p>
          </div>
        )}

        {estadoCarga === "listo" && visibles.length > 0 && filtradas.length === 0 && (
          <div className="estado-vacio">
            <p>Ninguna excepción coincide con la búsqueda.</p>
          </div>
        )}

        {estadoCarga === "listo" && filtradas.length > 0 && (
          <div className="tabla-desplazable">
            <table>
              <thead>
                <tr>
                  <th>Persona</th>
                  <th>Marca original</th>
                  {tipo === "dia_cerrado" ? (
                    <>
                      <th>Día de la marca</th>
                      <th>Estado del día</th>
                    </>
                  ) : (
                    <th>Motivo</th>
                  )}
                  <th>Detectada</th>
                  <th>Acción</th>
                </tr>
              </thead>
              <tbody>
                {filtradas.map((excepcion) => (
                  <tr key={excepcion.id}>
                    <td>
                      {excepcion.persona_nombre ??
                        (excepcion.dia_id !== null ? "Excepción de día" : "—")}
                    </td>
                    <td>{formatearFechaHora(excepcion.momento_dispositivo)}</td>
                    {tipo === "dia_cerrado" ? (
                      <>
                        <td className="num">
                          {formatearFechaCorta(excepcion.dia_de_la_marca_fecha) ?? "—"}
                        </td>
                        <td>
                          {excepcion.dia_de_la_marca_estado ? (
                            <Badge variante={VARIANTE_ESTADO_DIA[excepcion.dia_de_la_marca_estado]}>
                              {ETIQUETA_ESTADO_DIA[excepcion.dia_de_la_marca_estado]}
                            </Badge>
                          ) : (
                            "—"
                          )}
                        </td>
                      </>
                    ) : (
                      <td>
                        <Badge variante="aviso">
                          {etiquetaMotivo(excepcion.motivo_revision)}
                        </Badge>
                      </td>
                    )}
                    <td>{formatearFechaHora(excepcion.creado_en)}</td>
                    <td>{renderAccion(excepcion)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {aDescartar && (
          <DescartarMarcaTardiaModal
            excepcion={aDescartar}
            onCerrar={(refrescar) => {
              setADescartar(null);
              if (refrescar) cargar();
            }}
          />
        )}
      </div>
    </AppShell>
  );
}
