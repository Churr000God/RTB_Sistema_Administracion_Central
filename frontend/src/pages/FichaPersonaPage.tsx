import { type ChangeEvent, type FormEvent, useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import {
  AlertCircle,
  AlertTriangle,
  CalendarClock,
  KeyRound,
  Loader2,
  Pencil,
  Plus,
  RefreshCw,
  Repeat,
} from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { Input } from "../components/Input";
import { DetalleJornadaAsignada, type JornadaVigente } from "../components/DetalleJornadaAsignada";
import { derivarTransiciones, type Estado, type Movimiento } from "../lib/movimientos";

function aMayusculas(evento: ChangeEvent<HTMLInputElement>) {
  evento.currentTarget.value = evento.currentTarget.value.toUpperCase();
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

type PuestoVigente = {
  asignacion_id: string;
  puesto_id: string;
  nombre_puesto: string;
  nombre_departamento: string;
  nombre_area: string;
};

type Persona = {
  id: string;
  primer_nombre: string;
  segundo_nombre: string | null;
  apellido_paterno: string;
  apellido_materno: string | null;
  curp: string;
  rfc: string;
  nss: string;
  fecha_nacimiento: string;
  fecha_ingreso: string;
  estado: string;
  tipo_contrato: string | null;
  documento_ref: string | null;
  tiene_usuario: boolean;
  tiene_jornada_vigente: boolean;
  puestos_vigentes: PuestoVigente[];
};

type Asignacion = {
  id: string;
  persona_id: string;
  nombre_puesto: string;
  vigente_desde: string;
  vigente_hasta: string | null;
};

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

const ETIQUETA_TIPO_CONTRATO: Record<string, string> = {
  indefinido: "Indefinido",
  prestacion_servicios: "Prestación de servicios",
  por_proyecto: "Por proyecto",
};

function formatearFecha(fecha?: string | null): string {
  if (!fecha) return "—";
  // fecha_nacimiento/fecha_ingreso llegan como "AAAA-MM-DD" (sin hora) — agregar T00:00:00
  // evita que se interprete en UTC y se corra un día en zonas horarias negativas. Los
  // movimientos ya traen datetime completo (fecha_efectiva), no hay que tocarlos.
  const valor = fecha.includes("T") ? new Date(fecha) : new Date(`${fecha}T00:00:00`);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" });
}

type EstadoCarga = "cargando" | "listo" | "error";

type Motivo = "sin_marcas" | "fuera_de_tolerancia";

type AlertaRetardo = {
  fecha: string;
  hora_entrada_programada: string;
  hora_salida_programada: string;
  motivo: Motivo;
};

const ETIQUETA_MOTIVO_ALERTA: Record<Motivo, string> = {
  sin_marcas: "Sin marcas ese día",
  fuera_de_tolerancia: "Fuera de tolerancia",
};

// Ventana del resumen en la ficha — 30 días alcanza para una vista rápida sin salir del
// tope de 62 días que impone el backend; el historial completo vive en la pantalla de
// Reportes › Alertas de retardo (enlace "Ver todas").
const DIAS_VENTANA_RESUMEN_ALERTAS = 29;

function aFechaISO(fecha: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${fecha.getFullYear()}-${pad(fecha.getMonth() + 1)}-${pad(fecha.getDate())}`;
}

export function FichaPersonaPage() {
  const { id } = useParams<{ id: string }>();
  const [persona, setPersona] = useState<Persona | null>(null);
  const [movimientos, setMovimientos] = useState<Movimiento[]>([]);
  const [asignaciones, setAsignaciones] = useState<Asignacion[]>([]);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [alertas, setAlertas] = useState<AlertaRetardo[]>([]);
  // Independiente del resto de la ficha a propósito: el permiso de lectura de alertas
  // (clasificacion_de_tiempo_lectura) es distinto del que ya exige ver la ficha — si el caller
  // no lo tiene, la sección se oculta en vez de tirar abajo toda la página (mismo criterio
  // fail-soft que el resto de bloques opcionales de esta ficha).
  const [estadoAlertas, setEstadoAlertas] = useState<"cargando" | "listo" | "sin_permiso">(
    "cargando",
  );
  const [jornadaVigente, setJornadaVigente] = useState<JornadaVigente | null>(null);
  // "sin_jornada" (404 real del backend) es distinto de "sin_permiso" (403/otro error) — el
  // primero es un dato legítimo que sí se muestra ("sin jornada asignada todavía"), el segundo
  // oculta la tarjeta entera, mismo criterio fail-soft que la de alertas de acá arriba.
  const [estadoJornada, setEstadoJornada] = useState<
    "cargando" | "listo" | "sin_jornada" | "sin_permiso"
  >("cargando");
  const [editando, setEditando] = useState(false);
  const [guardando, setGuardando] = useState(false);
  const [errorEdicion, setErrorEdicion] = useState<string | null>(null);

  function cargar() {
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
      apiFetch("/api/asignaciones").then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      }),
    ])
      .then(([datosPersona, datosMovimientos, datosAsignaciones]: [Persona, Movimiento[], Asignacion[]]) => {
        setPersona(datosPersona);
        setMovimientos(datosMovimientos);
        setAsignaciones(datosAsignaciones.filter((a) => a.persona_id === id));
        setEstadoCarga("listo");
      })
      .catch(() => setEstadoCarga("error"));
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  useEffect(() => {
    if (!id) return;
    const hoy = new Date();
    const inicio = new Date(hoy);
    inicio.setDate(hoy.getDate() - DIAS_VENTANA_RESUMEN_ALERTAS);
    const params = new URLSearchParams({
      persona_id: id,
      desde: aFechaISO(inicio),
      hasta: aFechaISO(hoy),
    });
    apiFetch(`/api/alertas-de-retardo?${params.toString()}`)
      .then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      })
      .then((datos: { alertas?: AlertaRetardo[] }) => {
        setAlertas(datos.alertas ?? []);
        setEstadoAlertas("listo");
      })
      .catch(() => setEstadoAlertas("sin_permiso"));
  }, [id]);

  useEffect(() => {
    if (!id) return;
    apiFetch(`/api/personas/${id}/jornada-vigente`)
      .then((r) => {
        if (r.status === 404) {
          setEstadoJornada("sin_jornada");
          return null;
        }
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      })
      .then((datos: JornadaVigente | null) => {
        if (!datos || !Array.isArray(datos.patron_semanal)) return;
        setJornadaVigente(datos);
        setEstadoJornada("listo");
      })
      .catch(() => setEstadoJornada("sin_permiso"));
  }, [id]);

  function handleCancelar() {
    setEditando(false);
    setErrorEdicion(null);
  }

  async function handleGuardar(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    if (!persona) return;
    setErrorEdicion(null);
    const f = new FormData(evento.currentTarget);
    const primerNombre = String(f.get("primer_nombre") ?? "").trim();
    const segundoNombre = String(f.get("segundo_nombre") ?? "").trim() || null;
    const apellidoPaterno = String(f.get("apellido_paterno") ?? "").trim();
    const apellidoMaterno = String(f.get("apellido_materno") ?? "").trim() || null;
    const curp = String(f.get("curp") ?? "").trim();
    const rfc = String(f.get("rfc") ?? "").trim();
    const nss = String(f.get("nss") ?? "").trim();
    const fechaNacimiento = String(f.get("fecha_nacimiento") ?? "").trim();
    const fechaIngreso = String(f.get("fecha_ingreso") ?? "").trim();
    const tipoContrato = String(f.get("tipo_contrato") ?? "").trim() || null;
    const documentoRef = String(f.get("documento_ref") ?? "").trim() || null;

    // Sólo se manda lo que cambió — el PATCH acepta los 11 campos opcionales, pero mandar
    // valores sin tocar arriesga pisar una regla del backend (ej. documento_ref/tipo_contrato
    // deben ir juntos si la persona no tenía expediente previo).
    const cambios: Record<string, unknown> = {};
    if (primerNombre !== persona.primer_nombre) cambios.primer_nombre = primerNombre;
    if (segundoNombre !== persona.segundo_nombre) cambios.segundo_nombre = segundoNombre;
    if (apellidoPaterno !== persona.apellido_paterno) cambios.apellido_paterno = apellidoPaterno;
    if (apellidoMaterno !== persona.apellido_materno) cambios.apellido_materno = apellidoMaterno;
    if (curp !== persona.curp) cambios.curp = curp;
    if (rfc !== persona.rfc) cambios.rfc = rfc;
    if (nss !== persona.nss) cambios.nss = nss;
    if (fechaNacimiento !== persona.fecha_nacimiento) cambios.fecha_nacimiento = fechaNacimiento;
    if (fechaIngreso !== persona.fecha_ingreso) cambios.fecha_ingreso = fechaIngreso;
    if (tipoContrato !== persona.tipo_contrato) cambios.tipo_contrato = tipoContrato;
    if (documentoRef !== persona.documento_ref) cambios.documento_ref = documentoRef;

    if (Object.keys(cambios).length === 0) {
      setErrorEdicion("No modificaste ningún campo.");
      return;
    }

    setGuardando(true);
    const respuesta = await apiFetch(`/api/personas/${persona.id}`, {
      method: "PATCH",
      body: JSON.stringify(cambios),
    });
    if (!respuesta.ok) {
      if (respuesta.status === 403) {
        setErrorEdicion("No tenés permiso para editar esta persona.");
      } else if (respuesta.status === 404) {
        setErrorEdicion("Esta persona ya no existe.");
      } else {
        setErrorEdicion(await mensajeDeError(respuesta, "No se pudo guardar el cambio."));
      }
      setGuardando(false);
      return;
    }
    const actualizada = await respuesta.json();
    setPersona(actualizada);
    setGuardando(false);
    setEditando(false);
  }

  if (estadoCarga === "cargando") {
    return (
      <AppShell>
        <p className="contenedor-pagina" style={{ marginTop: "2.5rem" }}>
          <span className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando…
          </span>
        </p>
      </AppShell>
    );
  }

  if (estadoCarga === "error" || !persona) {
    return (
      <AppShell>
        <div className="contenedor-pagina" style={{ marginTop: "2.5rem" }}>
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar la ficha de esta persona
            </strong>
            <p>Ocurrió un problema al consultar el padrón.</p>
            <button type="button" onClick={cargar}>
              Reintentar
            </button>
          </div>
        </div>
      </AppShell>
    );
  }

  const nombreCompleto = [
    persona.primer_nombre,
    persona.segundo_nombre,
    persona.apellido_paterno,
    persona.apellido_materno,
  ]
    .filter(Boolean)
    .join(" ");
  const iniciales = `${persona.primer_nombre[0] ?? ""}${persona.apellido_paterno[0] ?? ""}`.toUpperCase();
  const idCorto = persona.id.slice(0, 8);
  const estado = persona.estado as Estado;

  const ultimosMovimientos = [...derivarTransiciones(movimientos)].reverse().slice(0, 3);
  const ultimosPuestos = [...asignaciones]
    .sort((a, b) => new Date(b.vigente_desde).getTime() - new Date(a.vigente_desde).getTime())
    .slice(0, 3);

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <a href="/personas">Personas</a> / <strong>{nombreCompleto}</strong>
        </nav>

        <div className="cabecera-persona cabecera-ficha">
          <div className="identidad">
            <span className="avatar-iniciales">{iniciales}</span>
            <div>
              <div className="fila-nombre-badge">
                <strong>{nombreCompleto}</strong>
                <span className={`insignia ${CLASE_ESTADO[estado] ?? "insignia--neutra"}`}>
                  {ETIQUETA_ESTADO[estado] ?? persona.estado}
                </span>
              </div>
              <p className="meta-ficha">
                ID {idCorto} · Ingreso {formatearFecha(persona.fecha_ingreso)}
              </p>
            </div>
          </div>
          <div className="botonera">
            {!persona.tiene_usuario && (
              <a href={`/usuarios/nuevo?persona_id=${persona.id}`} className="boton-con-icono">
                <KeyRound size={16} aria-hidden="true" />
                Crear acceso a Kairos
              </a>
            )}
            <a href={`/personas/${persona.id}/movimiento`} className="boton-con-icono boton-primario">
              <RefreshCw size={16} aria-hidden="true" />
              Nuevo movimiento
            </a>
          </div>
        </div>

        {editando ? (
          <Card as="form" onSubmit={handleGuardar}>
            <h3>Datos personales</h3>
            <div className="rejilla-campos">
              <Input
                id="primer_nombre"
                name="primer_nombre"
                label="Primer nombre"
                required
                defaultValue={persona.primer_nombre}
              />
              <Input
                id="segundo_nombre"
                name="segundo_nombre"
                label="Segundo nombre"
                defaultValue={persona.segundo_nombre ?? ""}
              />
              <Input
                id="apellido_paterno"
                name="apellido_paterno"
                label="Apellido paterno"
                required
                defaultValue={persona.apellido_paterno}
              />
              <Input
                id="apellido_materno"
                name="apellido_materno"
                label="Apellido materno"
                defaultValue={persona.apellido_materno ?? ""}
              />
              <Input
                id="curp"
                name="curp"
                label="CURP"
                required
                maxLength={18}
                className="campo-identificador"
                style={{ textTransform: "uppercase" }}
                onChange={aMayusculas}
                defaultValue={persona.curp}
                ayuda="18 caracteres"
              />
              <Input
                id="rfc"
                name="rfc"
                label="RFC"
                required
                maxLength={13}
                className="campo-identificador"
                style={{ textTransform: "uppercase" }}
                onChange={aMayusculas}
                defaultValue={persona.rfc}
                ayuda="13 caracteres con homoclave"
              />
              <Input
                id="nss"
                name="nss"
                label="NSS"
                required
                maxLength={11}
                className="campo-identificador"
                defaultValue={persona.nss}
                ayuda="11 dígitos"
              />
              <Input
                id="fecha_nacimiento"
                name="fecha_nacimiento"
                label="Fecha de nacimiento"
                type="date"
                required
                defaultValue={persona.fecha_nacimiento}
              />
              <Input
                id="fecha_ingreso"
                name="fecha_ingreso"
                label="Fecha de ingreso"
                type="date"
                required
                defaultValue={persona.fecha_ingreso}
              />
            </div>

            <h3 style={{ marginTop: "1.5rem" }}>Expediente</h3>
            <Input
              id="documento_ref"
              name="documento_ref"
              label="Referencia de documento (documento_ref)"
              placeholder="RTB-__-__"
              className="campo-identificador"
              defaultValue={persona.documento_ref ?? ""}
              ayuda="Formato RTB-__-__ · referencia única del expediente físico. Sólo se almacena esta referencia — no existe catálogo de documentos individuales por persona."
            />
            <div className="campo" style={{ marginTop: "1rem" }}>
              <label>Tipo de contrato</label>
              <div className="opciones-seleccionables opciones-seleccionables--compacta">
                <label className="opcion-seleccionable">
                  <input
                    type="radio"
                    name="tipo_contrato"
                    value="indefinido"
                    defaultChecked={persona.tipo_contrato === "indefinido"}
                  />
                  <span className="texto-opcion">
                    <strong>Indefinido</strong>
                  </span>
                </label>
                <label className="opcion-seleccionable">
                  <input
                    type="radio"
                    name="tipo_contrato"
                    value="prestacion_servicios"
                    defaultChecked={persona.tipo_contrato === "prestacion_servicios"}
                  />
                  <span className="texto-opcion">
                    <strong>Prestación de servicios</strong>
                  </span>
                </label>
                <label className="opcion-seleccionable">
                  <input
                    type="radio"
                    name="tipo_contrato"
                    value="por_proyecto"
                    defaultChecked={persona.tipo_contrato === "por_proyecto"}
                  />
                  <span className="texto-opcion">
                    <strong>Por proyecto</strong>
                  </span>
                </label>
              </div>
            </div>

            {errorEdicion && <p role="alert">{errorEdicion}</p>}
            <div className="botonera">
              <Button type="button" onClick={handleCancelar}>
                Cancelar
              </Button>
              <Button type="submit" variante="primario" cargando={guardando} textoCargando="Guardando…">
                Guardar
              </Button>
            </div>
          </Card>
        ) : (
          <>
            <div className="tarjeta-resumen">
              <div className="fila-cabecera-tarjeta">
                <h3>Datos personales</h3>
                <Button type="button" onClick={() => setEditando(true)} icono={Pencil} tamanoIcono={14}>
                  Editar
                </Button>
              </div>
              <div className="rejilla-datos">
                <div className="dato">
                  <span>Nombre completo</span>
                  <strong>{nombreCompleto}</strong>
                </div>
                <div className="dato">
                  <span>CURP</span>
                  <strong className="campo-identificador">{persona.curp}</strong>
                </div>
                <div className="dato">
                  <span>RFC</span>
                  <strong className="campo-identificador">{persona.rfc}</strong>
                </div>
                <div className="dato">
                  <span>NSS</span>
                  <strong className="campo-identificador">{persona.nss}</strong>
                </div>
                <div className="dato">
                  <span>Fecha de nacimiento</span>
                  <strong>{formatearFecha(persona.fecha_nacimiento)}</strong>
                </div>
              </div>
            </div>

            <div className="tarjeta-resumen">
              <h3>Expediente</h3>
              <div className="dato">
                <span>Referencia de documento (documento_ref)</span>
                {persona.documento_ref ? (
                  <p>
                    <span className="pildora-monoespaciada">{persona.documento_ref}</span>
                  </p>
                ) : (
                  <p>Sin expediente asignado.</p>
                )}
                <small className="ayuda-campo">
                  Formato RTB-__-__ · referencia única del expediente físico. Sólo se almacena esta
                  referencia — no existe catálogo de documentos individuales por persona.
                </small>
              </div>
              <div className="rejilla-datos" style={{ marginTop: "1rem" }}>
                <div className="dato">
                  <span>Tipo de contrato</span>
                  <strong>
                    {persona.tipo_contrato
                      ? ETIQUETA_TIPO_CONTRATO[persona.tipo_contrato] ?? persona.tipo_contrato
                      : "—"}
                  </strong>
                </div>
              </div>
            </div>
          </>
        )}

        <div className="tarjeta-resumen">
          <div className="fila-cabecera-tarjeta">
            <h3>Asignación actual</h3>
            <a
              href={`/estructura/asignaciones/nueva?persona_id=${persona.id}`}
              className="boton-con-icono enlace-etiqueta"
            >
              <Plus size={14} aria-hidden="true" />
              Nueva asignación
            </a>
          </div>
          {persona.puestos_vigentes.length === 0 ? (
            <p>Sin puesto asignado actualmente.</p>
          ) : (
            <ul className="lista-historial-resumido">
              {persona.puestos_vigentes.map((puestoVigente) => (
                <li key={puestoVigente.asignacion_id}>
                  <span style={{ fontWeight: 600 }}>{puestoVigente.nombre_puesto}</span>
                  <span className="fecha-historial">
                    {puestoVigente.nombre_departamento} · {puestoVigente.nombre_area}
                  </span>
                  <div className="botonera" style={{ justifyContent: "flex-start" }}>
                    <a href={`/estructura/asignaciones/${puestoVigente.asignacion_id}/terminar`}>Terminar</a>
                    <a
                      href={`/estructura/asignaciones/${puestoVigente.asignacion_id}/cambiar-puesto`}
                      className="boton-con-icono boton-primario"
                    >
                      <Repeat size={14} aria-hidden="true" />
                      Cambiar de puesto
                    </a>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>

        <div className="tarjeta-resumen">
          <div className="fila-cabecera-tarjeta">
            <h3>Historial de puestos</h3>
            <a href={`/personas/${persona.id}/bitacora-asignaciones`} className="enlace-etiqueta">
              Ver bitácora completa →
            </a>
          </div>
          {ultimosPuestos.length === 0 ? (
            <p>Sin asignaciones registradas todavía.</p>
          ) : (
            <ul className="lista-historial-resumido">
              {ultimosPuestos.map((asignacion) => (
                <li key={asignacion.id}>
                  <span className={`insignia ${asignacion.vigente_hasta ? "insignia--neutra" : "insignia--exito"}`}>
                    {asignacion.vigente_hasta ? "Terminada" : "Vigente"}
                  </span>
                  <span>{asignacion.nombre_puesto}</span>
                  <span className="fecha-historial">
                    {formatearFecha(asignacion.vigente_desde)}
                    {" — "}
                    {asignacion.vigente_hasta ? formatearFecha(asignacion.vigente_hasta) : "hoy"}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>

        {(estadoJornada === "listo" || estadoJornada === "sin_jornada") && (
          <div className="tarjeta-resumen">
            <div className="fila-cabecera-tarjeta">
              <h3>Jornada asignada</h3>
              <a
                href={`/tiempo/asignacion-jornada?persona_id=${persona.id}`}
                className="boton-con-icono enlace-etiqueta"
              >
                <CalendarClock size={14} aria-hidden="true" />
                {jornadaVigente ? "Renovar jornada" : "Asignar jornada"}
              </a>
            </div>
            <DetalleJornadaAsignada estado={estadoJornada} jornada={jornadaVigente} />
          </div>
        )}

        {estadoAlertas === "listo" && (
          <div className="tarjeta-resumen">
            <div className="fila-cabecera-tarjeta">
              <h3>Alertas de retardo</h3>
              <a
                href={`/tiempo/alertas-retardo?persona_id=${persona.id}`}
                className="enlace-etiqueta"
              >
                Ver todas →
              </a>
            </div>
            {alertas.length === 0 ? (
              <p>Sin alertas de retardo en los últimos {DIAS_VENTANA_RESUMEN_ALERTAS + 1} días.</p>
            ) : (
              <ul className="lista-historial-resumido">
                {alertas.slice(0, 5).map((alerta) => (
                  <li key={`${alerta.fecha}-${alerta.motivo}`}>
                    <span className="insignia insignia--aviso">
                      <AlertTriangle size={12} aria-hidden="true" />
                      {ETIQUETA_MOTIVO_ALERTA[alerta.motivo]}
                    </span>
                    <span className="fecha-historial">{formatearFecha(alerta.fecha)}</span>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}

        <div className="tarjeta-resumen">
          <div className="fila-cabecera-tarjeta">
            <h3>Historial de estado</h3>
            <a href={`/personas/${persona.id}/bitacora`} className="enlace-etiqueta">
              Ver bitácora completa →
            </a>
          </div>
          {ultimosMovimientos.length === 0 ? (
            <p>Sin movimientos registrados todavía.</p>
          ) : (
            <ul className="lista-historial-resumido">
              {ultimosMovimientos.map((movimiento) => (
                <li key={movimiento.id}>
                  <span className={`insignia ${CLASE_ESTADO[movimiento.estadoNuevo]}`}>
                    {ETIQUETA_ESTADO[movimiento.estadoNuevo]}
                  </span>
                  <span className="fecha-historial">{formatearFecha(movimiento.fecha_efectiva)}</span>
                  <span className="autor-historial">{movimiento.registrado_por_nombre ?? "Sistema"}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </AppShell>
  );
}
