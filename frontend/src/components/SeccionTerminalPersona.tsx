import { useCallback, useEffect, useState } from "react";
import { AlertCircle, AlertTriangle, CheckCircle2, Fingerprint, Loader2, UserPlus } from "lucide-react";

import { AsignarPersonaTerminalModal } from "./AsignarPersonaTerminalModal";
import { Button } from "./Button";
import { Card } from "./Card";
import { ConfirmarHuellaModal } from "./ConfirmarHuellaModal";
import { CuentaRegresivaAlta } from "./CuentaRegresivaAlta";
import { EvidenciaHuella } from "./EvidenciaHuella";
import { EstadoAltaBadge } from "./EstadoAltaBadge";
import { apiJson } from "../lib/errorApi";
import { useSesion } from "../lib/useSesion";
import {
  etiquetaEvidencia,
  muestraEvidencia,
  type AltaDePersona,
  type PersonaAsignable,
  type Terminal,
} from "../lib/terminales";

type Props = { persona: PersonaAsignable };

type Estado = "cargando" | "listo" | "error";

// Sección «Terminal de checado» de la ficha de persona (SCJ-PRO-15 §VI.5). La ve quien ya ve la
// ficha y tiene terminal_usuario_lectura|edicion (puede_ver_terminales); el botón sólo con edición.
export function SeccionTerminalPersona({ persona }: Props) {
  const { sesion, cargando: cargandoSesion } = useSesion();
  const oculta = sesion?.puede_ver_terminales === false;
  const puedeEditar = sesion?.puede_editar_terminales === true;

  const [altas, setAltas] = useState<AltaDePersona[]>([]);
  const [estado, setEstado] = useState<Estado>("cargando");
  const [abriendo, setAbriendo] = useState(false);
  const [errorAsignar, setErrorAsignar] = useState(false);
  const [terminalesElegibles, setTerminalesElegibles] = useState<{ id: number; nombre: string }[] | null>(null);
  const [confirmando, setConfirmando] = useState<AltaDePersona | null>(null);

  const cargar = useCallback(() => {
    setEstado("cargando");
    apiJson<AltaDePersona[]>(`/api/personas/${persona.persona_id}/terminales`)
      .then((datos) => {
        if (!Array.isArray(datos)) throw new Error("forma inesperada");
        setAltas(datos);
        setEstado("listo");
      })
      .catch(() => setEstado("error"));
  }, [persona.persona_id]);

  useEffect(() => {
    if (cargandoSesion || oculta) return;
    cargar();
  }, [cargandoSesion, oculta, cargar]);

  const vigentes = altas.filter(({ alta }) => alta.estado !== "baja");

  async function abrirAsignar() {
    setAbriendo(true);
    setErrorAsignar(false);
    try {
      const terminales = await apiJson<Terminal[]>("/api/terminales");
      const ocupadas = new Set(vigentes.map(({ terminal }) => terminal.id));
      setTerminalesElegibles(
        terminales.filter((t) => t.activa && !ocupadas.has(t.id)).map((t) => ({ id: t.id, nombre: t.nombre })),
      );
    } catch {
      setErrorAsignar(true);
    } finally {
      setAbriendo(false);
    }
  }

  if (oculta) return null;

  return (
    <Card>
      <div className="fila-cabecera-tarjeta">
        <h3>
          <Fingerprint size={18} aria-hidden="true" /> Terminal de checado
        </h3>
        {estado === "listo" && puedeEditar && vigentes.length === 0 && (
          <Button icono={UserPlus} posicionIcono="izquierda" tamanoIcono={14} cargando={abriendo} textoCargando="Abriendo…" onClick={abrirAsignar}>
            Asignar a la terminal
          </Button>
        )}
      </div>

      {estado === "cargando" && (
        <p className="boton-con-icono" role="status">
          <Loader2 size={16} className="icono-girando" aria-hidden="true" />
          Cargando…
        </p>
      )}

      {estado === "error" && (
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            No se pudo cargar la información de la terminal
          </strong>
          <p>El resto de la ficha sigue disponible.</p>
          <Button onClick={cargar}>Reintentar</Button>
        </div>
      )}

      {errorAsignar && (
        <p role="alert" className="mensaje-campo">
          <AlertCircle size={14} aria-hidden="true" />
          No se pudo consultar las terminales. Inténtalo de nuevo.
        </p>
      )}

      {estado === "listo" && vigentes.length === 0 && (
        <>
          <p style={{ margin: "0.5rem 0 0" }}>
            No está asignada a ninguna terminal. Marca por <strong>captura manual</strong>, que no requiere
            asignación ni consentimiento biométrico.
          </p>
          {!puedeEditar && (
            <p className="ayuda-campo" style={{ margin: "0.5rem 0 0" }}>
              Asignarla requiere el permiso <span className="chip-permiso">terminal_usuario_edicion</span>.
            </p>
          )}
        </>
      )}

      {estado === "listo" &&
        vigentes.map(({ alta, terminal }) => (
          <div key={alta.id} style={{ marginTop: "0.75rem" }}>
            <p style={{ margin: "0 0 0.4rem" }}>
              <EstadoAltaBadge estado={alta.estado} />{" "}
              {alta.reconsentimiento_pendiente && (
                <span className="insignia insignia--peligro estado-alta">
                  <AlertTriangle size={12} aria-hidden="true" />
                  Reconsentimiento pendiente
                </span>
              )}{" "}
              · {terminal.nombre} · nº {alta.employee_no}
              {muestraEvidencia(alta.estado) && etiquetaEvidencia(alta.huella_evidencia, alta.huellas_capturadas) && (
                <>
                  {" · "}
                  <EvidenciaHuella alta={alta} />
                </>
              )}
            </p>
            {alta.estado === "esperando_huella" && (
              <>
                <p className="ayuda-campo" style={{ margin: 0 }}>
                  Esperando que TI enrole la huella en la terminal. Se activa sola con su primera marca por huella.
                </p>
                {puedeEditar && (
                  <p style={{ margin: "0.4rem 0 0" }}>
                    <Button icono={CheckCircle2} posicionIcono="izquierda" tamanoIcono={14} onClick={() => setConfirmando({ alta, terminal })}>
                      Confirmar huella
                    </Button>
                  </p>
                )}
                {alta.caduca_en && <CuentaRegresivaAlta caducaEn={alta.caduca_en} />}
              </>
            )}
            {alta.estado === "pendiente_baja" && (
              <p className="ayuda-campo" style={{ margin: 0 }}>
                El puente borrará el usuario y sus huellas del aparato. Reactivar a la persona no la reenrola:
                habrá que asignarla de nuevo.
              </p>
            )}
            {alta.reconsentimiento_pendiente && (
              <p className="ayuda-campo" style={{ margin: 0 }}>
                Confirmó el texto v{alta.consentimiento?.version ?? "?"}; hay una versión vigente más nueva. No
                afecta sus marcas: sólo se señala hasta que RH registre su nuevo consentimiento.
              </p>
            )}
            <p style={{ margin: "0.5rem 0 0" }}>
              <a href={`/tiempo/terminales/${terminal.id}/usuarios`}>Ver en Usuarios de la terminal →</a>
            </p>
          </div>
        ))}

      {confirmando && (
        <ConfirmarHuellaModal
          terminalId={confirmando.terminal.id}
          terminalNombre={confirmando.terminal.nombre}
          alta={confirmando.alta}
          onCerrar={(refrescar) => {
            setConfirmando(null);
            if (refrescar) cargar();
          }}
        />
      )}

      {terminalesElegibles && (
        <AsignarPersonaTerminalModal
          terminales={terminalesElegibles}
          personaFija={persona}
          personaDelCaller={sesion?.persona_id}
          onCerrar={(refrescar) => {
            setTerminalesElegibles(null);
            if (refrescar) cargar();
          }}
        />
      )}
    </Card>
  );
}
