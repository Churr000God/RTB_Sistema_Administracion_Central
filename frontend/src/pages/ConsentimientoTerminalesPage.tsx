import { useCallback, useEffect, useState } from "react";
import { AlertCircle, AlertTriangle, CheckCircle2, Eye, Info, Loader2, Lock } from "lucide-react";

import { Badge } from "../components/Badge";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { ConfiguracionTerminalesLayout } from "../components/ConfiguracionTerminalesLayout";
import { PublicarConsentimientoPanel } from "../components/PublicarConsentimientoPanel";
import { SinAccesoTerminales } from "../components/SinAccesoTerminales";
import { formatearHoraMexico } from "../lib/calendario";
import { ErrorApi, apiJson } from "../lib/errorApi";
import { useSesion } from "../lib/useSesion";
import {
  TEXTO_SEMILLA,
  type ConsentimientoVigente,
  type RespuestaConsentimiento,
  type ResultadoPublicar,
} from "../lib/terminales";

const RUTA = "/api/terminales/configuracion/consentimiento";
const MAX_TEXTO = 4000;
const MENSAJE_VERSION_404 = "La versión de consentimiento solicitada no existe.";

type Estado = "cargando" | "listo" | "error" | "sin_acceso";
type EstadoVersion = "cargando" | "listo" | "error" | "no_existe";

function formatearFecha(fecha: string | null | undefined): string {
  if (!fecha) return "—";
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "—";
  return formatearHoraMexico(valor, { day: "2-digit", month: "short", year: "numeric" });
}

function quienPublico(version: ConsentimientoVigente): string {
  if (version.publicado_por_nombre) return version.publicado_por_nombre;
  return version.es_semilla ? TEXTO_SEMILLA : "—";
}

function esRespuestaValida(datos: RespuestaConsentimiento | null): datos is RespuestaConsentimiento {
  return !!datos && !!datos.vigente && typeof datos.vigente.version === "number" && Array.isArray(datos.historial);
}

export function ConsentimientoTerminalesPage() {
  const { sesion, cargando: cargandoSesion } = useSesion();
  const sinAccesoPorSesion = sesion?.puede_ver_terminales === false;
  const puedeEditar = sesion?.puede_editar_config_terminales === true;

  const [vigente, setVigente] = useState<ConsentimientoVigente | null>(null);
  const [historial, setHistorial] = useState<ConsentimientoVigente[]>([]);
  const [estado, setEstado] = useState<Estado>("cargando");
  const [borrador, setBorrador] = useState("");
  const [editado, setEditado] = useState(false);
  const [publicando, setPublicando] = useState(false);
  const [resultado, setResultado] = useState<ResultadoPublicar | null>(null);
  const [conflicto, setConflicto] = useState<{ detalle: string; nueva: ConsentimientoVigente | null } | null>(null);

  const [versionVista, setVersionVista] = useState<number | null>(null);
  const [textoVersion, setTextoVersion] = useState<string | null>(null);
  const [estadoVersion, setEstadoVersion] = useState<EstadoVersion>("cargando");

  const cargar = useCallback((conservarBorrador: boolean) => {
    setEstado("cargando");
    apiJson<RespuestaConsentimiento>(RUTA)
      .then((datos) => {
        if (!esRespuestaValida(datos)) throw new Error("forma inesperada");
        setVigente(datos.vigente);
        setHistorial(datos.historial);
        if (!conservarBorrador) {
          setBorrador(datos.vigente.texto ?? "");
          setEditado(false);
        }
        setEstado("listo");
      })
      .catch((error) => setEstado(error instanceof ErrorApi && error.status === 403 ? "sin_acceso" : "error"));
  }, []);

  useEffect(() => {
    if (cargandoSesion || sinAccesoPorSesion) return;
    cargar(false);
  }, [cargandoSesion, sinAccesoPorSesion, cargar]);

  const verTexto = useCallback((version: number) => {
    setVersionVista(version);
    setEstadoVersion("cargando");
    setTextoVersion(null);
    apiJson<ConsentimientoVigente>(`${RUTA}/${version}`)
      .then((datos) => {
        setTextoVersion(datos.texto ?? "");
        setEstadoVersion("listo");
      })
      .catch((error) => setEstadoVersion(error instanceof ErrorApi && error.status === 404 ? "no_existe" : "error"));
  }, []);

  function alPublicar(r: ResultadoPublicar) {
    setPublicando(false);
    setResultado(r);
    setConflicto(null);
    cargar(false);
  }

  function recargarConflicto() {
    if (conflicto?.nueva) {
      setVigente(conflicto.nueva);
      setConflicto(null);
    } else {
      setConflicto(null);
      cargar(true);
    }
  }

  const sinAcceso = sinAccesoPorSesion || estado === "sin_acceso";
  const textoActual = vigente?.texto ?? "";
  const hayCambios = borrador !== textoActual;
  const puedeRevisar = hayCambios && borrador.trim().length > 0 && borrador.length <= MAX_TEXTO;
  const tituloVista = hayCambios ? `Versión ${(vigente?.version ?? 0) + 1} (borrador, sin publicar)` : `Versión ${vigente?.version} (vigente)`;

  return (
    <ConfiguracionTerminalesLayout activa="consentimiento">
      {sinAcceso && <SinAccesoTerminales />}

      {!sinAcceso && estado === "cargando" && (
        <p className="boton-con-icono" role="status">
          <Loader2 size={16} className="icono-girando" aria-hidden="true" />
          Cargando el texto de consentimiento…
        </p>
      )}

      {!sinAcceso && estado === "error" && (
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            No se pudo cargar la configuración
          </strong>
          <p>Ocurrió un problema al consultar el texto de consentimiento.</p>
          <Button onClick={() => cargar(false)}>Reintentar</Button>
        </div>
      )}

      {!sinAcceso && vigente && (estado === "listo" || estado === "cargando") && (
        <>
          {!puedeEditar && (
            <div className="banner-aviso banner-aviso--info" role="note">
              <Lock size={16} aria-hidden="true" />
              <div>
                <strong>Puedes consultar el texto, no modificarlo.</strong> Publicar una versión nueva requiere{" "}
                <span className="chip-permiso">terminal_config_edicion</span> (Gerente o Encargado de TI, Gerente
                General).
              </div>
            </div>
          )}

          {vigente.provisional && (
            <div className="banner-aviso" role="note">
              <AlertTriangle size={16} aria-hidden="true" />
              <div>
                <strong>El texto vigente es provisional.</strong> Es el texto inicial del sistema; el aviso definitivo
                lo entrega RH/Legal. Las asignaciones lo muestran con la marca «Provisional». Deja de serlo
                publicando una versión nueva.
              </div>
            </div>
          )}

          {resultado?.resultado === "publicada" && (
            <div className="banner-aviso banner-aviso--info" role="status">
              <CheckCircle2 size={16} aria-hidden="true" />
              <div>
                <strong>Versión {resultado.version} publicada.</strong>{" "}
                {resultado.cambio_material && resultado.pendientes > 0 ? (
                  <>
                    {resultado.pendientes} altas quedaron con <strong>reconsentimiento pendiente</strong>.{" "}
                    <a href="/tiempo/terminales">Ver terminales y registrar reconsentimientos →</a>
                  </>
                ) : (
                  "Aplica a las asignaciones nuevas desde ahora. Las altas ya hechas conservan la versión con la que se confirmaron."
                )}
              </div>
            </div>
          )}
          {resultado?.resultado === "sin_cambio" && (
            <div className="banner-aviso banner-aviso--info" role="status">
              <Info size={16} aria-hidden="true" />
              <div>
                El texto es igual al vigente (versión {resultado.version}): no se publicó una versión nueva.
              </div>
            </div>
          )}

          {conflicto && (
            <div className="tarjeta-error" role="alert">
              <strong>
                <AlertCircle size={16} aria-hidden="true" />
                No se publicó
              </strong>
              <p>{conflicto.detalle}</p>
              <p className="ayuda-campo">Tu texto no se perdió: sigue en el editor.</p>
              <Button onClick={recargarConflicto}>Recargar versión vigente</Button>
            </div>
          )}

          <div className="rejilla-editor">
            <Card className="editor-texto">
              <h3>Versión vigente</h3>
              <div className="version-vigente">
                <Badge variante={vigente.provisional ? "aviso" : "exito"}>
                  {vigente.provisional ? "Provisional" : "Vigente"}
                </Badge>
                <strong>Versión {vigente.version}</strong>
                <span className="rango">
                  desde {formatearFecha(vigente.vigente_desde)} · publicada por {quienPublico(vigente)}
                </span>
              </div>

              {puedeEditar ? (
                <>
                  <label htmlFor="consentimiento-texto">
                    Texto de consentimiento (texto plano, hasta {MAX_TEXTO} caracteres)
                  </label>
                  <textarea
                    id="consentimiento-texto"
                    maxLength={MAX_TEXTO}
                    value={borrador}
                    disabled={publicando}
                    aria-describedby="consentimiento-ayuda consentimiento-contador"
                    onChange={(evento) => {
                      setBorrador(evento.target.value);
                      setEditado(true);
                    }}
                  />
                  <p className="ayuda-campo" id="consentimiento-ayuda">
                    Se muestra en el modal de asignar, junto a la casilla. No uses HTML ni formato: se muestra como
                    texto. El aviso de privacidad completo es un documento aparte.
                  </p>
                  <div className="modal__contador num" id="consentimiento-contador">
                    {borrador.length} / {MAX_TEXTO}
                  </div>

                  {!publicando && (
                    <div className="botonera" style={{ marginTop: "0.5rem" }}>
                      <Button
                        disabled={!editado || !hayCambios}
                        onClick={() => {
                          setBorrador(textoActual);
                          setEditado(false);
                        }}
                      >
                        Descartar cambios
                      </Button>
                      <Button variante="primario" disabled={!puedeRevisar} onClick={() => setPublicando(true)}>
                        Revisar y publicar…
                      </Button>
                    </div>
                  )}

                  {publicando && (
                    <PublicarConsentimientoPanel
                      texto={borrador}
                      vigente={vigente}
                      onVolver={() => setPublicando(false)}
                      onPublicado={alPublicar}
                      onConflicto={(detalle, nueva) => {
                        setPublicando(false);
                        setConflicto({ detalle, nueva });
                      }}
                    />
                  )}
                </>
              ) : (
                <>
                  <p
                    style={{ whiteSpace: "pre-line", background: "var(--superficie)", padding: "0.8rem", borderRadius: 10, fontSize: "0.9rem", margin: 0 }}
                  >
                    {vigente.texto}
                  </p>
                  <p className="rango" style={{ margin: "0.5rem 0 0" }}>
                    Sólo lectura.
                  </p>
                </>
              )}
            </Card>

            <div>
              <div className="vista-previa" role="region" aria-label="Vista previa del modal de asignar">
                <h4>Vista previa — así se ve en «Asignar persona»</h4>
                <div className="casilla-consentimiento" style={{ background: "#fff" }}>
                  <input type="checkbox" disabled aria-hidden="true" tabIndex={-1} />
                  <div>
                    <strong>Consentimiento y aviso de privacidad recabados.</strong>
                    <span style={{ display: "block", fontWeight: 400, color: "var(--navy-medio)", whiteSpace: "pre-line" }}>
                      {puedeEditar ? borrador : textoActual}
                    </span>
                    <span className="rango" style={{ display: "block", marginTop: "0.4rem" }}>
                      {puedeEditar ? tituloVista : `Versión ${vigente.version} (vigente)`}
                      {vigente.provisional && !hayCambios && (
                        <>
                          {" "}
                          <Badge variante="aviso">Provisional</Badge>
                        </>
                      )}
                    </span>
                  </div>
                </div>
                <p className="ayuda-campo" style={{ margin: "0.6rem 0 0" }}>
                  El título en negrita es fijo (es el acto que se confirma). Sólo el texto de abajo se edita.
                </p>
              </div>

              <Card style={{ marginTop: "1.25rem" }}>
                <h3>Historial de versiones</h3>
                <div className="tabla-desplazable">
                  <table>
                    <thead>
                      <tr>
                        <th>Versión</th>
                        <th>Vigente desde</th>
                        <th>Hasta</th>
                        <th>Publicada por</th>
                        <th>Motivo del cambio</th>
                        <th>Estado</th>
                        <th>Texto</th>
                      </tr>
                    </thead>
                    <tbody>
                      {historial.map((v) => {
                        const esVigente = v.version === vigente.version;
                        return (
                          <tr key={v.id}>
                            <td>{v.version}</td>
                            <td className="num">{formatearFecha(v.vigente_desde)}</td>
                            <td className="num">{esVigente ? "—" : formatearFecha(v.vigente_hasta)}</td>
                            <td>{quienPublico(v)}</td>
                            <td>
                              {v.motivo_cambio ?? "—"}{" "}
                              {v.cambio_material && <Badge variante="peligro">Cambio material</Badge>}
                            </td>
                            <td>
                              <Badge variante={esVigente ? "exito" : "neutra"}>{esVigente ? "Vigente" : "Reemplazada"}</Badge>{" "}
                              {v.provisional && <Badge variante="aviso">Provisional</Badge>}
                            </td>
                            <td>
                              {esVigente ? (
                                <span className="rango">Texto vigente (arriba)</span>
                              ) : (
                                <button
                                  type="button"
                                  className="enlace-porque"
                                  aria-expanded={versionVista === v.version}
                                  aria-controls="ver-texto-version"
                                  aria-label={`Ver texto de la versión ${v.version}`}
                                  onClick={() => verTexto(v.version)}
                                >
                                  <Eye size={14} aria-hidden="true" /> Ver texto
                                </button>
                              )}
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>

                {versionVista !== null && (
                  <div id="ver-texto-version" style={{ marginTop: "1rem" }}>
                    <div className="vista-previa">
                      <h4>Texto de la versión {versionVista} · sólo lectura</h4>
                      {estadoVersion === "cargando" && (
                        <p className="boton-con-icono" role="status" style={{ margin: 0 }}>
                          <Loader2 size={16} className="icono-girando" aria-hidden="true" />
                          Cargando el texto de la versión {versionVista}…
                        </p>
                      )}
                      {estadoVersion === "listo" && (
                        <p style={{ whiteSpace: "pre-line", margin: 0, fontSize: "0.9rem" }}>{textoVersion}</p>
                      )}
                      {estadoVersion === "error" && (
                        <div className="tarjeta-error" role="alert">
                          <strong>
                            <AlertCircle size={16} aria-hidden="true" />
                            No se pudo cargar el texto de esta versión
                          </strong>
                          <p>Ocurrió un problema al consultar la versión {versionVista}.</p>
                          <Button onClick={() => verTexto(versionVista)}>Reintentar</Button>
                        </div>
                      )}
                      {estadoVersion === "no_existe" && (
                        <div className="tarjeta-error" role="alert">
                          <strong>
                            <AlertCircle size={16} aria-hidden="true" />
                            La versión no existe
                          </strong>
                          <p>{MENSAJE_VERSION_404}</p>
                        </div>
                      )}
                    </div>
                  </div>
                )}
                <p className="ayuda-campo" style={{ margin: "0.6rem 0 0" }}>
                  Cada alta registra qué versión confirmó RH. El historial no trae el texto de cada versión: «Ver
                  texto» lo pide aparte. Ver una versión antigua es sólo lectura.
                </p>
              </Card>
            </div>
          </div>
        </>
      )}
    </ConfiguracionTerminalesLayout>
  );
}
