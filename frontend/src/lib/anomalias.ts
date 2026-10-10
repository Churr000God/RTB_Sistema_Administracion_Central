import { formatearFechaCorta, formatearHoraMexico } from "./calendario";
import { textoDeCodigoDeEstado } from "./interruptorHuella";
import { ETIQUETA_ESTADO_ALTA, ETIQUETA_EVIDENCIA_SIN_CONTEO, formatearDesfase, type EstadoAlta } from "./terminales";

export type EstadoTarjeta = "sin_hallazgos" | "con_hallazgos" | "no_disponible" | "error";
export type NivelAnomalia = "atender" | "revisar" | "informativo";

export type TarjetaAnomalia = {
  clave: string;
  numero: number;
  titulo: string;
  estado: EstadoTarjeta;
  nivel: NivelAnomalia | null;
  total: number | null;
  ejemplos: Record<string, unknown>[];
  hay_mas: boolean;
  motivo: "sin_permiso" | "falta_migracion" | null;
  // Texto fijo de contexto del backend (categoría 11); se pinta como texto plano.
  nota?: string | null;
};

export type RespuestaAnomalias = {
  terminal_id: number;
  desde: string;
  hasta: string;
  generado_en: string;
  categorias: TarjetaAnomalia[];
};

export type DetalleAnomalia = { clave: string; total: number; items: Record<string, unknown>[] };

export function esRespuestaAnomalias(datos: unknown): datos is RespuestaAnomalias {
  return !!datos && typeof datos === "object" && Array.isArray((datos as RespuestaAnomalias).categorias);
}

function texto(valor: unknown, vacio = "—"): string {
  return typeof valor === "string" && valor.length > 0 ? valor : typeof valor === "number" ? String(valor) : vacio;
}

function fechaHora(valor: unknown): string {
  if (typeof valor !== "string") return "—";
  const fecha = new Date(valor);
  if (Number.isNaN(fecha.getTime())) return "—";
  return formatearHoraMexico(fecha, { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
}

function fechaDia(valor: unknown): string {
  return typeof valor === "string" ? (formatearFechaCorta(valor) ?? "—") : "—";
}

const ESTADO_PERSONA: Record<string, string> = {
  suspension: "suspendida",
  baja_definitiva: "en baja definitiva",
};

const ESTADO_ALTA = (valor: unknown): string => ETIQUETA_ESTADO_ALTA[valor as EstadoAlta] ?? texto(valor);

// Una línea de texto PLANO por hallazgo (los nombres vienen del servidor: nunca se interpretan como HTML).
// Nunca se muestran ids de persona, employee_no, hashes ni IP: el backend tampoco los manda.
export function describirHallazgo(clave: string, e: Record<string, unknown>): string {
  switch (clave) {
    case "marcas_posteriores_a_baja":
      return `${texto(e.persona_nombre)} · marcó el ${fechaHora(e.marca_en)}, después de la baja confirmada el ${fechaHora(e.baja_confirmada_en)}`;
    case "picos_de_tasa":
      return `${e.persona_nombre ? texto(e.persona_nombre) : "Terminal"} · ${texto(e.marcas)} marcas en la hora ${fechaHora(e.hora)} (límite ${texto(e.limite)} por hora)`;
    case "reloj_degradado":
      return `${texto(e.conteo)} marcas con reloj con deriva o sin sincronizar · desfase actual: ${formatearDesfase(typeof e.desfase_actual_seg === "number" ? e.desfase_actual_seg : null)}`;
    case "huecos_de_secuencia":
      return `Secuencia ${texto(e.desde)} → ${texto(e.hasta)} (faltan ${texto(e.faltan)}) el ${fechaDia(e.fecha)}`;
    case "rechazos_definitivos":
      return `${texto(e.codigo)}: ${texto(e.total)} rechazos`;
    case "credenciales":
      switch (e.tipo) {
        case "llave_antigua":
          return `Llave del puente con ${texto(e.antiguedad_meses)} meses de antigüedad (rotar)`;
        case "llave_sin_uso":
          return `Llave del puente sin uso desde hace ${texto(e.antiguedad_dias)} días`;
        case "traslape_abierto":
          return `Traslape de llaves abierto hace ${texto(e.dias_abierto)} días`;
        case "cambio_de_ip":
          return `Cambio de IP del puente hace ${texto(e.hace_dias)} días`;
        default:
          return "Hallazgo de credenciales";
      }
    case "inconsistencias_de_baja":
      if (e.estado_persona === "inexistente") {
        return `La persona ya no existe y su alta sigue ${ESTADO_ALTA(e.estado_alta)}`;
      }
      return `${texto(e.persona_nombre)} · ${ESTADO_PERSONA[String(e.estado_persona)] ?? texto(e.estado_persona)}, pero su alta sigue ${ESTADO_ALTA(e.estado_alta)}`;
    case "altas_atascadas":
      return `${texto(e.persona_nombre)} · ${ESTADO_ALTA(e.estado)} · ${texto(e.horas)} h`;
    case "altas_recientes":
      return `${texto(e.persona_nombre)} (asignó ${texto(e.asignada_por)}) · ${fechaHora(e.creado_en)}`;
    case "reconsentimientos_pendientes":
      return `${texto(e.persona_nombre)} · confirmó v${texto(e.version_confirmada, "?")} · vigente v${texto(e.version_vigente, "?")} · pendiente hace ${texto(e.dias_pendiente, "?")} días`;
    case "huellas_inferidas_exceso":
      return `${fechaDia(e.dia)}: ${texto(e.activaciones)} activaciones, ${texto(e.inferidas)} inferidas y ${texto(e.manuales)} manuales (límite de inferidas por día: ${texto(e.limite_inferidas)})`;
    case "inferida_sin_marcas": {
      const evidencia = e.evidencia === "inferida" || e.evidencia === "manual" ? ETIQUETA_EVIDENCIA_SIN_CONTEO[e.evidencia] : "Huella activada";
      return `${texto(e.persona_nombre)} · ${evidencia} · activada ${fechaHora(e.activada_en)}, sin marcas posteriores en 7 días`;
    }
    case "interruptor_huella":
      return textoDeCodigoDeEstado(typeof e.codigo === "string" ? e.codigo : null, typeof e.mensaje === "string" ? e.mensaje : null) ?? "Revisa el interruptor de la activación por huella";
    case "asignador_confirmador":
      return `${texto(e.persona_nombre)} · la huella la confirmó ${texto(e.confirmada_por)}, que también asignó el alta · ${fechaHora(e.confirmada_en)}`;
    default:
      return "Hallazgo sin descripción";
  }
}
