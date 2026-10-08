import { codigoDe, type ErrorApi } from "./errorApi";

// Tipos y utilidades del módulo Terminales (contrato: docs/07-procesos/CONTRATO_API_TERMINALES_PAQUETE_2.md).
// El texto que llega del servidor (nombres, detalle de errores) se pinta SIEMPRE como texto plano.

export type EstadoAlta = "pendiente_alta" | "esperando_huella" | "activo" | "pendiente_baja" | "baja";
export type EstadoContacto = "en_linea" | "sin_contacto" | "nunca" | "inactiva";

export type Terminal = {
  id: number;
  serie: string;
  nombre: string;
  modelo: string | null;
  activa: boolean;
  estado_contacto: EstadoContacto;
  ultimo_contacto_en: string | null;
  segundos_sin_contacto: number | null;
  terminal_alcanzable: boolean | null;
  reloj_desfase_seg: number | null;
  version_pi: string | null;
  marcas_pendientes: number;
};

export type ConsentimientoResumen = { id: number; version: number; provisional: boolean };

export type RazonNoElegible = "es_propia" | "ya_al_corriente" | "en_baja";

export type Alta = {
  id: number;
  terminal_id: number;
  employee_no: number;
  persona_id: string;
  persona_nombre: string | null;
  estado: EstadoAlta;
  huellas_capturadas: number;
  creado_en: string;
  actualizado_en: string;
  usuario_creado_en: string | null;
  caduca_en: string | null;
  error_codigo: string | null;
  error_detalle: string | null;
  consentimiento: ConsentimientoResumen | null;
  consentimiento_vigente_id: number | null;
  reconsentimiento_pendiente: boolean;
  es_propia: boolean;
  reconsentimiento_elegible: boolean;
  reconsentimiento_razon: RazonNoElegible | null;
  accion_disponible: "cancelar_alta" | "dar_de_baja" | null;
};

export type RespuestaAltas = {
  total: number;
  resumen: {
    por_estado: Partial<Record<EstadoAlta, number>>;
    reconsentimiento_pendiente: number;
  };
  altas: Alta[];
};

export const ETIQUETA_ESTADO_ALTA: Record<EstadoAlta, string> = {
  pendiente_alta: "Pendiente de alta",
  esperando_huella: "Esperando huella",
  activo: "Activo",
  pendiente_baja: "Pendiente de baja",
  baja: "Baja",
};

export const ETIQUETA_CONTACTO: Record<EstadoContacto, string> = {
  en_linea: "En línea",
  sin_contacto: "Sin contacto",
  nunca: "Sin conexión todavía",
  inactiva: "Inactiva",
};

export type CuentaRegresiva = { texto: string; urgente: boolean; vencida: boolean };

// Tiempo restante antes de que un alta en "Esperando huella" caduque. La fecha la calcula el
// servidor (caduca_en) con la variable vigente: el cliente nunca asume 24 h.
export function cuentaRegresiva(caducaEn: string, ahora: Date = new Date()): CuentaRegresiva | null {
  const destino = new Date(caducaEn).getTime();
  if (Number.isNaN(destino)) return null;
  const restanteMs = destino - ahora.getTime();
  // Se redondea hacia arriba: con 19 h 39 min 59 s restantes se lee «19 h 40 min», no «19 h 39».
  const minutos = Math.ceil(restanteMs / 60_000);
  if (restanteMs <= 0) {
    return { texto: "Venció; se dará de baja en la siguiente corrida", urgente: true, vencida: true };
  }
  const horas = Math.floor(minutos / 60);
  const resto = String(minutos % 60).padStart(2, "0");
  if (minutos <= 60) {
    const tiempo = horas > 0 ? `${horas} h ${resto} min` : `${minutos} min`;
    return { texto: `Caduca en ${tiempo} · se dará de baja sola`, urgente: true, vencida: false };
  }
  return { texto: `Caduca en ${horas} h ${resto} min`, urgente: false, vencida: false };
}

export function descripcionUltimoContacto(segundos: number | null): string {
  if (segundos === null) return "—";
  if (segundos < 60) return `hace ${segundos} s`;
  if (segundos < 3600) return `hace ${Math.floor(segundos / 60)} min`;
  if (segundos < 86400) return `hace ${Math.floor(segundos / 3600)} h`;
  const dias = Math.floor(segundos / 86400);
  return `hace ${dias} ${dias === 1 ? "día" : "días"}`;
}

export function formatearDesfase(segundos: number | null): string {
  if (segundos === null) return "—";
  if (segundos > 0) return `+${segundos} s`;
  return `${segundos} s`;
}

export type ConsentimientoVigente = {
  id: number;
  version: number;
  texto: string | null;
  texto_sha256?: string | null;
  provisional: boolean;
  cambio_material: boolean;
  motivo_cambio?: string | null;
  vigente_desde: string;
  vigente_hasta?: string | null;
  publicado_por_nombre?: string | null;
  es_semilla?: boolean;
};

export type RespuestaConsentimiento = {
  vigente: ConsentimientoVigente;
  historial: ConsentimientoVigente[];
};

export type PersonaAsignable = {
  persona_id: string;
  nombre: string;
  puesto: string | null;
  area: string | null;
};

// «Ana Torres — Auxiliar de almacén · Bodega»: puesto y área distinguen homónimos; si no hay
// asignación vigente sólo el nombre.
export function etiquetaPersonaAsignable(persona: PersonaAsignable): string {
  const detalle = [persona.puesto, persona.area].filter(Boolean).join(" · ");
  return detalle ? `${persona.nombre} — ${detalle}` : persona.nombre;
}

export type TipoMovimiento =
  | "asignado"
  | "usuario_creado"
  | "huella_capturada"
  | "error"
  | "baja_solicitada"
  | "baja_confirmada"
  | "reconsentido";

export const ETIQUETA_MOVIMIENTO: Record<TipoMovimiento, string> = {
  asignado: "Asignada",
  usuario_creado: "Usuario creado en el aparato",
  huella_capturada: "Huella capturada",
  error: "Error del puente",
  baja_solicitada: "Baja solicitada",
  baja_confirmada: "Baja confirmada",
  reconsentido: "Reconsentimiento registrado",
};

export type MovimientoAlta = {
  id: number;
  tipo_movimiento: TipoMovimiento;
  creado_en: string;
  origen: "web" | "terminal";
  registrado_por_nombre: string | null;
  detalle: string | null;
  huellas_capturadas: number | null;
  consentimiento: { id: number; version: number; cambio_material?: boolean } | null;
};

export type AltaDePersona = {
  alta: Alta;
  terminal: { id: number; nombre: string; serie: string; estado_contacto: EstadoContacto; activa: boolean };
};

export type ImpactoConsentimiento = {
  cambio_material_efectivo: boolean;
  forzado: boolean;
  altas_que_quedarian_pendientes: number;
  en_proceso: number;
  activas: number;
  pendientes_actuales: number;
};

export type ResultadoPublicar =
  | { resultado: "publicada"; id: number; version: number; cambio_material: boolean; cambio_material_forzado: boolean; pendientes: number }
  | { resultado: "sin_cambio"; version: number };

export const TEXTO_SEMILLA = "Sistema (texto provisional)";

export type VariableTerminal = {
  clave: string;
  etiqueta: string;
  descripcion: string;
  unidad: string;
  minimo: number;
  maximo: number;
  valor_defecto: number;
  valor: number;
  vigente_desde: string | null;
  modificado_por_nombre: string | null;
  valor_ilegible: boolean;
};

export type VigenciaVariable = {
  clave: string;
  valor: string;
  vigente_desde: string;
  vigente_hasta: string | null;
  modificado_por_nombre: string | null;
  estado: "vigente" | "reemplazada";
  valor_ilegible: boolean;
};

export type SimulacionCaducidad = {
  valor_actual: number;
  valor_propuesto: number;
  acorta: boolean;
  altas_en_espera: number;
  altas_que_ganan_plazo: number;
  altas_que_caducarian_ya: { tu_id: number; persona_nombre: string | null; esperando_desde: string }[];
  altas_que_caducarian_ya_total: number;
  altas_por_caducar_nuevas: number;
  tope_por_corrida: number;
};

export const CLAVE_CADUCIDAD = "terminal_caducidad_alta_horas";

// El cuerpo de un 409 no es de fiar: sólo se reemplaza el estado con una versión de consentimiento
// COMPLETA (id y version numéricos, texto no vacío). Si no cumple, se vuelve a pedir al servidor.
export function esConsentimientoCompleto(valor: unknown): valor is ConsentimientoVigente {
  if (!valor || typeof valor !== "object") return false;
  const v = valor as Record<string, unknown>;
  return (
    typeof v.id === "number" &&
    Number.isFinite(v.id) &&
    typeof v.version === "number" &&
    Number.isFinite(v.version) &&
    typeof v.texto === "string" &&
    v.texto.length > 0
  );
}

const CODIGOS_CONSENTIMIENTO_DESACTUALIZADO = ["consentimiento_desactualizado", "version_base_desactualizada"];

// ¿Este 409 es «el texto de consentimiento cambió»? Prioriza el código estable del backend; sólo si no
// viene (backend anterior) reconoce el texto del detail.
export function esConflictoDeConsentimiento(error: ErrorApi): boolean {
  const codigo = codigoDe(error);
  if (codigo) return CODIGOS_CONSENTIMIENTO_DESACTUALIZADO.includes(codigo);
  return !!error.detail && /consentimiento/i.test(error.detail);
}

export const ETIQUETA_RAZON_NO_ELEGIBLE: Record<string, string> = {
  es_propia: "No puedes registrar tu propio reconsentimiento; lo registra otra persona con permiso.",
  ya_al_corriente: "Ya estaba al corriente (alguien más lo registró).",
  en_baja: "Su alta está en baja o pendiente de baja.",
  no_encontrada: "La alta ya no existe en esta terminal.",
};

export type NoElegible = { tu_id: number; persona_nombre?: string | null; razon: string };

export type ResultadoReconsentimiento = {
  registradas: number;
  pendientes_restantes?: number;
  omitidas?: unknown[];
};

export const MAX_LOTE_RECONSENTIMIENTO = 200;
