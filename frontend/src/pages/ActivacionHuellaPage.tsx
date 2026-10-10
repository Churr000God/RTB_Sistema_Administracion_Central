import { useCallback, useEffect, useState } from "react";
import { AlertCircle, AlertTriangle, CheckCircle2, Clock, Fingerprint, History, Loader2, Lock, X } from "lucide-react";

import { ApagarInterruptorHuellaModal } from "../components/ApagarInterruptorHuellaModal";
import { Badge } from "../components/Badge";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { CambiarInterruptorHuellaModal, type AvisoInterruptor } from "../components/CambiarInterruptorHuellaModal";
import { ConfiguracionTerminalesLayout } from "../components/ConfiguracionTerminalesLayout";
import { HistorialInterruptorHuella } from "../components/HistorialInterruptorHuella";
import { SinAccesoTerminales } from "../components/SinAccesoTerminales";
import { formatearFechaCorta, formatearHoraMexico } from "../lib/calendario";
import { ErrorApi, apiJson } from "../lib/errorApi";
import {
  HORA_VENCIMIENTO,
  RUTA_INTERRUPTOR,
  UMBRAL_ACTIVACIONES_POR_DIA,
  esEstadoInterruptor,
  textoDeCodigoDeEstado,
  type EstadoInterruptorHuella,
} from "../lib/interruptorHuella";
import { useSesion } from "../lib/useSesion";

type Estado = "cargando" | "listo" | "error" | "sin_acceso";
type Modal = "encender" | "renovar" | "apagar" | null;

function fechaHora(valor: string | null): string {
  if (!valor) return "—";
  const fecha = new Date(valor);
  if (Number.isNaN(fecha.getTime())) return "—";
  return formatearHoraMexico(fecha, { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
}

// «24 oct 2026, 23:59 (hora de México)»: se muestra siempre con la hora para que nadie lo lea como
// medianoche UTC.
function vencimiento(estado: EstadoInterruptorHuella): string {
  const fecha = formatearFechaCorta(estado.hasta_fecha);
  return fecha ? `${fecha}, ${HORA_VENCIMIENTO} (hora de México)` : "—";
}

function InsigniaEstado({ estado }: { estado: EstadoInterruptorHuella }) {
  const atender = estado.alarma.activa && estado.alarma.nivel === "atender";
  const sinRegistro = atender && estado.estado === "encendido";
  if (estado.estado === "encendido") {
    return (
      <Badge variante={sinRegistro ? "peligro" : "exito"} className="estado-alta">
        {sinRegistro ? <AlertTriangle size={12} aria-hidden="true" /> : <CheckCircle2 size={12} aria-hidden="true" />}
        Encendido hasta el {vencimiento(estado)}
        {sinRegistro ? " · sin registro válido" : ""}
      </Badge>
    );
  }
  if (estado.estado === "vencido") {
    return (
      <Badge variante="aviso" className="estado-alta">
        <Clock size={12} aria-hidden="true" />
        Vencido · venció el {vencimiento(estado)}
      </Badge>
    );
  }
  if (estado.estado === "inconsistente") {
    return (
      <Badge variante={atender ? "peligro" : "aviso"} className="estado-alta">
        <AlertTriangle size={12} aria-hidden="true" />
        {atender ? "Apagado por seguridad" : "Apagado · ajuste inconsistente"}
      </Badge>
    );
  }
  return (
    <Badge variante="neutra" className="estado-alta">
      <X size={12} aria-hidden="true" />
      Apagado
    </Badge>
  );
}

export function ActivacionHuellaPage() {
  const { sesion, cargando: cargandoSesion } = useSesion();
  const sinAccesoPorSesion = sesion?.puede_ver_terminales === false;
  const puedeCambiar = sesion?.puede_editar_config_terminales === true;
  // Nombre de quien lo encendió, notas e historial: sólo terminal_config_edicion y terminal_usuario_edicion.
  const veDetalle = puedeCambiar || sesion?.puede_editar_terminales === true;

  const [datos, setDatos] = useState<EstadoInterruptorHuella | null>(null);
  const [estado, setEstado] = useState<Estado>("cargando");
  const [modal, setModal] = useState<Modal>(null);
  const [aviso, setAviso] = useState<AvisoInterruptor | null>(null);
  const [versionHistorial, setVersionHistorial] = useState(0);

  const cargar = useCallback(() => {
    setEstado("cargando");
    apiJson<unknown>(RUTA_INTERRUPTOR)
      .then((respuesta) => {
        // Un estado ilegible NUNCA se rellena con «apagado»: es una pantalla de error.
        if (!esEstadoInterruptor(respuesta)) throw new Error("forma inesperada");
        setDatos(respuesta);
        setEstado("listo");
      })
      .catch((error) => setEstado(error instanceof ErrorApi && error.status === 403 ? "sin_acceso" : "error"));
  }, []);

  useEffect(() => {
    if (cargandoSesion || sinAccesoPorSesion) return;
    cargar();
  }, [cargandoSesion, sinAccesoPorSesion, cargar]);

  function alActualizar(nuevo: EstadoInterruptorHuella, mensaje: AvisoInterruptor) {
    setDatos(nuevo);
    setEstado("listo");
    setAviso(mensaje);
    setModal(null);
    setVersionHistorial((v) => v + 1);
  }

  const sinAcceso = sinAccesoPorSesion || estado === "sin_acceso";
  const alarma = datos?.alarma;
  const requisitoFalta =
    datos?.requisitos?.consentimiento_publicado === false
      ? "consentimiento"
      : datos?.requisitos?.terminal_activa === false
        ? "terminal"
        : null;
  const encendido = datos?.estado === "encendido";
  const conAlarmaAtender = alarma?.activa === true && alarma.nivel === "atender";

  return (
    <ConfiguracionTerminalesLayout activa="huella">
      {sinAcceso && <SinAccesoTerminales />}

      {!sinAcceso && estado === "cargando" && !datos && (
        <p className="boton-con-icono" role="status">
          <Loader2 size={16} className="icono-girando" aria-hidden="true" />
          Cargando el estado…
        </p>
      )}

      {!sinAcceso && estado === "error" && (
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            No se pudo cargar el estado de la activación por huella
          </strong>
          <p>El servicio no respondió como se esperaba; intenta de nuevo o avisa a Sistemas.</p>
          <Button onClick={cargar}>Reintentar</Button>
        </div>
      )}

      {!sinAcceso && datos && (estado === "listo" || estado === "cargando") && (
        <>
          {!puedeCambiar && sesion && (
            <div className="banner-aviso banner-aviso--info" role="note">
              <Lock size={16} aria-hidden="true" />
              <div>
                {veDetalle ? (
                  <>
                    <strong>Puedes consultar este ajuste y su historial, no modificarlo.</strong> Encenderlo, renovarlo o
                    apagarlo requiere <span className="chip-permiso">terminal_config_edicion</span> (Gerente o Encargado
                    de TI, Gerente General).
                  </>
                ) : (
                  <>
                    <strong>Ves el estado del ajuste, no quién lo encendió ni el historial.</strong> El nombre de quien
                    lo encendió, la nota y el historial de cambios requieren{" "}
                    <span className="chip-permiso">terminal_usuario_edicion</span> o{" "}
                    <span className="chip-permiso">terminal_config_edicion</span>. Cambiarlo requiere{" "}
                    <span className="chip-permiso">terminal_config_edicion</span>.
                  </>
                )}
              </div>
            </div>
          )}

          {aviso && (
            <div role="status">
              <div className={aviso.tipo === "exito" ? "banner-aviso banner-aviso--info" : "banner-aviso"}>
                {aviso.tipo === "exito" ? <CheckCircle2 size={16} aria-hidden="true" /> : <AlertTriangle size={16} aria-hidden="true" />}
                <div>{aviso.texto}</div>
              </div>
            </div>
          )}

          {alarma?.activa && alarma.nivel === "atender" && (
            <div className="tarjeta-error" role="alert" style={{ marginTop: "1rem" }}>
              <strong>
                <AlertTriangle size={16} aria-hidden="true" />
                Atender · {textoDeCodigoDeEstado(alarma.codigo, alarma.mensaje) ?? "Revisa este ajuste."}
              </strong>
              {encendido && (
                <p>
                  <strong>Recomendado: apágalo</strong> y, si hace falta, vuelve a encenderlo desde aquí para dejar el
                  motivo asentado.
                </p>
              )}
            </div>
          )}
          {alarma?.activa && alarma.nivel === "revisar" && (
            <div className="banner-aviso" role="alert" style={{ marginTop: "1rem" }}>
              <AlertTriangle size={16} aria-hidden="true" />
              <div>
                <strong>Revisar · </strong>
                {textoDeCodigoDeEstado(alarma.codigo, alarma.mensaje) ?? "Revisa este ajuste."}
              </div>
            </div>
          )}

          <Card style={{ marginTop: "1rem" }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: "1rem", flexWrap: "wrap" }}>
              <div>
                <h3 style={{ margin: "0 0 0.4rem" }}>
                  <Fingerprint size={18} aria-hidden="true" /> Activación de altas por huella
                </h3>
                <p style={{ margin: "0 0 0.6rem" }}>
                  <InsigniaEstado estado={datos} />
                </p>
              </div>
              {puedeCambiar && (
                <div className="botonera">
                  {!encendido && (
                    <Button
                      variante="primario"
                      icono={Fingerprint}
                      posicionIcono="izquierda"
                      tamanoIcono={14}
                      disabled={requisitoFalta !== null}
                      aria-describedby={requisitoFalta ? "interruptor-requisito" : undefined}
                      onClick={() => setModal("encender")}
                    >
                      {datos.estado === "vencido" ? "Encender de nuevo…" : "Encender…"}
                    </Button>
                  )}
                  {encendido && (
                    <>
                      {conAlarmaAtender ? (
                        <Button className="boton-peligro" icono={X} posicionIcono="izquierda" tamanoIcono={14} onClick={() => setModal("apagar")}>
                          Apagar…
                        </Button>
                      ) : (
                        <Button icono={History} posicionIcono="izquierda" tamanoIcono={14} onClick={() => setModal("renovar")}>
                          Renovar…
                        </Button>
                      )}
                      {conAlarmaAtender ? (
                        <Button icono={History} posicionIcono="izquierda" tamanoIcono={14} onClick={() => setModal("renovar")}>
                          Renovar con registro…
                        </Button>
                      ) : (
                        <Button icono={X} posicionIcono="izquierda" tamanoIcono={14} onClick={() => setModal("apagar")}>
                          Apagar…
                        </Button>
                      )}
                    </>
                  )}
                </div>
              )}
            </div>

            {puedeCambiar && !encendido && requisitoFalta === "consentimiento" && (
              <p className="ayuda-campo" id="interruptor-requisito" style={{ margin: "0.2rem 0 0.4rem" }}>
                <Lock size={14} aria-hidden="true" /> No se puede encender todavía: falta publicar el texto de
                consentimiento biométrico definitivo (hoy sólo existe el provisional).{" "}
                <a href="/tiempo/terminales/configuracion">Ir a Texto de consentimiento →</a>
              </p>
            )}
            {puedeCambiar && !encendido && requisitoFalta === "terminal" && (
              <p className="ayuda-campo" id="interruptor-requisito" style={{ margin: "0.2rem 0 0.4rem" }}>
                <Lock size={14} aria-hidden="true" /> No se puede encender todavía: no hay ninguna terminal activa.{" "}
                <a href="/tiempo/terminales">Ver Terminales →</a>
              </p>
            )}

            <dl style={{ margin: "0.5rem 0 0", display: "grid", gridTemplateColumns: "max-content 1fr", gap: "0.25rem 1rem", fontSize: "0.9rem" }}>
              {encendido && (
                <>
                  {veDetalle && (
                    <>
                      <dt className="rango">Encendido por</dt>
                      <dd style={{ margin: 0 }}>
                        {datos.encendido_por_nombre ?? "Sin registro"}
                        {datos.encendido_en ? ` · ${fechaHora(datos.encendido_en)}` : ""}
                      </dd>
                    </>
                  )}
                  <dt className="rango">Activo hasta</dt>
                  <dd style={{ margin: 0 }}>
                    {vencimiento(datos)} <span className="rango">(se apaga solo al vencer)</span>
                  </dd>
                  {datos.altas_activadas_desde_encendido !== null && datos.altas_activadas_desde_encendido !== undefined && (
                    <>
                      <dt className="rango">Altas activadas por esta vía</dt>
                      <dd style={{ margin: 0 }}>
                        {datos.altas_activadas_desde_encendido} desde que se encendió <span className="rango">(informativo)</span>
                        {datos.altas_activadas_desde_encendido > UMBRAL_ACTIVACIONES_POR_DIA && (
                          <div className="ayuda-campo">
                            Son más de {UMBRAL_ACTIVACIONES_POR_DIA} en total: es normal en un alta supervisada. Si llegaron
                            el mismo día, revisa la anomalía 11 del <a href="/tiempo/terminales/anomalias">tablero</a>.
                          </div>
                        )}
                        <div className="ayuda-campo">Apagar y volver a encender reinicia el conteo; renovar no.</div>
                      </dd>
                    </>
                  )}
                </>
              )}
              {datos.estado === "vencido" && (
                <>
                  <dt className="rango">Venció</dt>
                  <dd style={{ margin: 0 }}>
                    {vencimiento(datos)} · <strong>ya no activa altas</strong>. {textoDeCodigoDeEstado(datos.motivo, datos.mensaje) ?? ""}
                  </dd>
                </>
              )}
              {datos.estado === "apagado" && (
                <>
                  <dt className="rango">Estado</dt>
                  <dd style={{ margin: 0 }}>
                    Apagado. Las altas nuevas se activan con «Confirmar huella» (una persona atestigua la huella).
                  </dd>
                </>
              )}
              {datos.estado === "inconsistente" && (
                <>
                  <dt className="rango">Estado</dt>
                  <dd style={{ margin: 0 }}>Apagado por falla cerrada. No hay un vencimiento vigente.</dd>
                </>
              )}
            </dl>
          </Card>

          <div className="banner-aviso" role="note" style={{ marginTop: "1rem" }}>
            <AlertTriangle size={16} aria-hidden="true" />
            <div>
              <strong>Qué implica encenderla.</strong> Mientras esté activa, la <strong>primera marca verificada por huella</strong>{" "}
              de un usuario recién dado de alta lo activa por sí sola: queda «Activo» con la evidencia «Huella verificada en
              el aparato», sin que una persona confirme la huella. Es una verificación indirecta (no hay conteo de huellas).{" "}
              <strong>Se recomienda apagarla al terminar el alta supervisada</strong>; por eso siempre lleva vencimiento
              (máximo {datos.maximo_dias} días) y se apaga sola al vencer.
              <ul style={{ margin: "0.5rem 0 0", paddingLeft: "1.1rem", fontSize: "0.86rem", lineHeight: 1.5 }}>
                <li>
                  Está <strong>apagada de fábrica</strong>. Para encenderla hace falta una nota con el motivo, un
                  vencimiento y el <a href="/tiempo/terminales/configuracion">texto de consentimiento definitivo</a>{" "}
                  publicado (el provisional no alcanza).
                </li>
                <li>
                  No cambia a las altas ya activas ni a las que se confirman a mano con «Confirmar huella»; esa vía sigue
                  disponible siempre.
                </li>
              </ul>
            </div>
          </div>

          <HistorialInterruptorHuella puedeVer={veDetalle} version={versionHistorial} />
        </>
      )}

      {modal === "apagar" && datos && (
        <ApagarInterruptorHuellaModal onActualizado={alActualizar} onCerrar={() => setModal(null)} />
      )}
      {(modal === "encender" || modal === "renovar") && datos && (
        <CambiarInterruptorHuellaModal
          modo={modal}
          estado={datos}
          onActualizado={alActualizar}
          onRecargar={() => {
            setModal(null);
            cargar();
          }}
          onCerrar={() => setModal(null)}
        />
      )}
    </ConfiguracionTerminalesLayout>
  );
}
