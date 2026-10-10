import { ErrorApi, codigoDe } from "./errorApi";
import { formatearHoraMexico, hoyISO, sumarDiasISO } from "./calendario";

// Contrato: docs/07-procesos/CONTRATO_API_INTERRUPTOR_INFERIR_HUELLA.md (v2). Todo texto que llega del
// servidor (nombres, notas, mensajes) se pinta SIEMPRE como texto plano.

export const RUTA_INTERRUPTOR = "/api/terminales/configuracion/activacion-por-huella";

export type EstadoInterruptor = "encendido" | "apagado" | "vencido" | "inconsistente";
export type NivelAlarma = "atender" | "revisar";

export type AlarmaInterruptor = {
  activa: boolean;
  nivel: NivelAlarma | null;
  codigo: string | null;
  mensaje: string | null;
};

export type EstadoInterruptorHuella = {
  activo: boolean;
  estado: EstadoInterruptor;
  motivo: string | null;
  mensaje: string | null;
  // Instante UTC real que guardó la base (para comparar) y la misma fecha civil en México (para mostrar).
  hasta: string | null;
  hasta_fecha: string | null;
  vencido: boolean;
  encendido_por_nombre: string | null;
  encendido_en: string | null;
  altas_activadas_desde_encendido: number | null;
  maximo_dias: number;
  fecha_minima: string;
  fecha_maxima: string;
  nota_minimo: number;
  nota_maximo: number;
  requisitos: { consentimiento_publicado: boolean; terminal_activa: boolean } | null;
  alarma: AlarmaInterruptor;
};

export type ResultadoCambio = { resultado: "actualizada" | "sin_cambio"; estado: EstadoInterruptorHuella };

export type ItemHistorialInterruptor = {
  id: number;
  creado_en: string;
  clave: string;
  operacion: string;
  valor_anterior: string | null;
  valor_nuevo: string | null;
  nota: string | null;
  autor_nombre: string | null;
  via_funcion: boolean;
};

const ESTADOS: EstadoInterruptor[] = ["encendido", "apagado", "vencido", "inconsistente"];

// Un estado que no se puede interpretar jamás se rellena: la pantalla muestra error, no «apagado».
export function esEstadoInterruptor(datos: unknown): datos is EstadoInterruptorHuella {
  if (!datos || typeof datos !== "object") return false;
  const d = datos as Record<string, unknown>;
  const alarma = d.alarma as Record<string, unknown> | null | undefined;
  return (
    typeof d.activo === "boolean" &&
    typeof d.estado === "string" &&
    (ESTADOS as string[]).includes(d.estado) &&
    typeof d.fecha_minima === "string" &&
    typeof d.fecha_maxima === "string" &&
    !!alarma &&
    typeof alarma === "object" &&
    typeof alarma.activa === "boolean"
  );
}

export function esResultadoCambio(datos: unknown): datos is ResultadoCambio {
  if (!datos || typeof datos !== "object") return false;
  const d = datos as Record<string, unknown>;
  return (d.resultado === "actualizada" || d.resultado === "sin_cambio") && esEstadoInterruptor(d.estado);
}

export const MIN_NOTA_INTERRUPTOR = 10;
export const MAX_NOTA_INTERRUPTOR = 500;

// Mismo saneo que aplica el servidor antes de medir: espacios colapsados y recortados.
export function sanearNota(texto: string): string {
  return texto.replace(/\s+/g, " ").trim();
}

export function notaValida(texto: string): boolean {
  const largo = sanearNota(texto).length;
  return largo >= MIN_NOTA_INTERRUPTOR && largo <= MAX_NOTA_INTERRUPTOR;
}

// Atajo «en N días»: hoy + N, siempre dentro del rango que el servidor permite.
export function fechaDeAtajo(dias: number, minima: string, maxima: string, hoy: string = hoyISO()): string {
  const candidata = sumarDiasISO(hoy, dias);
  if (candidata < minima) return minima;
  if (candidata > maxima) return maxima;
  return candidata;
}

export function fechaEnRango(fecha: string, minima: string, maxima: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(fecha) && fecha >= minima && fecha <= maxima;
}

// El vencimiento es la fecha elegida a las 23:59:59 hora de México. Se muestra siempre con la hora
// para que nadie lo lea como medianoche UTC.
export const HORA_VENCIMIENTO = "23:59";

// Umbral de la anomalía 11 (más de 5 activaciones inferidas en un día). El conteo del interruptor es
// el acumulado desde que se encendió: sólo se usa para sugerir revisar el tablero, nunca como alarma.
export const UMBRAL_ACTIVACIONES_POR_DIA = 5;

// Instante UTC de la bitácora -> «02 nov 2026» en hora de México. El centinela de apagado (1970) o un
// valor que no es fecha se muestran como «—», nunca como texto crudo.
function fechaDeInstante(valor: string | null): string {
  if (!valor) return "—";
  const fecha = new Date(valor);
  if (Number.isNaN(fecha.getTime()) || fecha.getUTCFullYear() <= 1970) return "—";
  return formatearHoraMexico(fecha, { day: "2-digit", month: "short", year: "numeric" });
}

// Clave -> nombre legible. Una clave desconocida se muestra como «Otro ajuste», sin interpretar el valor.
export function describirCambio(
  item: Pick<ItemHistorialInterruptor, "clave" | "valor_anterior" | "valor_nuevo"> & { operacion?: string },
): string {
  // Renovar sólo mueve el vencimiento: la bitácora lo registra como UPDATE_VIGENCIA con el mismo valor antes y
  // después, y «Encendido → Encendido» confundiría.
  if (item.operacion === "UPDATE_VIGENCIA") return "Cambio de vigencia (sin cambio de valor)";
  const activa = (v: string | null) => (v === "1" ? "Encendido" : v === "0" ? "Apagado" : "—");
  if (item.clave === "terminal_inferir_huella_activa") {
    return `Interruptor: ${activa(item.valor_anterior)} → ${activa(item.valor_nuevo)}`;
  }
  if (item.clave === "terminal_inferir_huella_hasta") {
    return `Vencimiento: ${fechaDeInstante(item.valor_anterior)} → ${fechaDeInstante(item.valor_nuevo)}`;
  }
  return "Otro ajuste";
}

// Texto fijo por código estable (contrato §6.1). Siempre se usa el texto local: el detail del servidor no se
// pinta nunca. Un código desconocido cae al texto genérico, sin interpolar nada del servidor.
const TEXTO_POR_CODIGO: Record<string, string> = {
  reintentar: "El cambio no se pudo aplicar por una operación concurrente; vuelve a intentarlo.",
  nota_requerida: "La nota debe tener entre 10 y 500 caracteres.",
  nota_repetida: "Escribe un motivo nuevo para la renovación.",
  hasta_invalido: "El vencimiento debe ser una fecha futura de a lo más 30 días.",
  cuerpo_invalido: "La solicitud no es válida.",
  terminal_no_activa: "No hay ninguna terminal activa; no se puede encender.",
  sin_consentimiento_vigente:
    "Falta publicar el texto de consentimiento biométrico definitivo; mientras solo exista el provisional no se puede encender.",
  ya_esta_encendido: "Ya está encendido; usa Renovar para cambiar el vencimiento.",
  no_esta_encendido: "Ya no está encendido (venció o alguien lo apagó).",
  estado_desactualizado: "El estado cambió mientras tenías la ventana abierta.",
  vigencias_inconsistentes: "El ajuste está en un estado inconsistente; avisa a Sistemas.",
};

const GENERICO = "No se pudo completar. Inténtalo de nuevo.";

export function textoDeError(error: unknown): string {
  if (error instanceof ErrorApi) {
    const codigo = codigoDe(error);
    if (codigo && TEXTO_POR_CODIGO[codigo]) return TEXTO_POR_CODIGO[codigo];
    if (error.status === 403) return "No tienes permiso para cambiar el interruptor de la activación por huella.";
    if (error.status === 503) return "Servicio no disponible; reintenta.";
  }
  return GENERICO;
}

// Estado que el backend devuelve junto a un 409 para refrescar la pantalla (ya_esta_encendido,
// estado_desactualizado). Sólo se acepta si tiene la forma completa.
export function estadoDelError(error: unknown): EstadoInterruptorHuella | null {
  if (!(error instanceof ErrorApi)) return null;
  const estado = error.cuerpo?.estado;
  return esEstadoInterruptor(estado) ? estado : null;
}

// Textos fijos de la alarma y del motivo del estado, por código (contrato §6.2). El mensaje que manda el
// servidor sólo sirve de respaldo para un código que esta pantalla todavía no conoce.
const TEXTO_FUERA_DE_FUNCION = "El interruptor está encendido pero su último cambio no quedó registrado como debe. Avisa a Sistemas.";
const TEXTO_VALOR_NO_VALIDO = "El ajuste tiene un valor no válido; el interruptor quedó apagado. Avisa a Sistemas.";
const TEXTO_NO_SE_PUDO_LEER = "No se pudo leer el ajuste; el interruptor quedó apagado. Avisa a Sistemas.";

const TEXTO_POR_CODIGO_DE_ESTADO: Record<string, string> = {
  vencido: "El vencimiento ya pasó; el interruptor está apagado.",
  sin_respaldo_de_la_funcion: "Se detectó un cambio hecho fuera de esta pantalla; el interruptor quedó apagado. Avisa a Sistemas.",
  cambio_fuera_de_la_funcion: TEXTO_FUERA_DE_FUNCION,
  sin_registro: TEXTO_FUERA_DE_FUNCION,
  vigencias_inconsistentes: "El ajuste está en un estado inconsistente; el interruptor quedó apagado. Avisa a Sistemas.",
  valor_invalido: TEXTO_VALOR_NO_VALIDO,
  hasta_ilegible: TEXTO_VALOR_NO_VALIDO,
  hasta_excede_tope: TEXTO_VALOR_NO_VALIDO,
  error: TEXTO_NO_SE_PUDO_LEER,
  estado_ilegible: TEXTO_NO_SE_PUDO_LEER,
};

export function textoDeCodigoDeEstado(codigo: string | null | undefined, respaldo?: string | null): string | null {
  if (codigo && TEXTO_POR_CODIGO_DE_ESTADO[codigo]) return TEXTO_POR_CODIGO_DE_ESTADO[codigo];
  return respaldo ?? null;
}
