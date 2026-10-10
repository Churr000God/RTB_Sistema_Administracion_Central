// Fixtures del contrato del interruptor de la activación por huella (CONTRATO_API_INTERRUPTOR_INFERIR_HUELLA.md v2).
export const ESTADO_APAGADO = {
  activo: false,
  estado: "apagado",
  motivo: "apagado",
  mensaje: null,
  hasta: null,
  hasta_fecha: null,
  vencido: false,
  encendido_por_nombre: null,
  encendido_en: null,
  altas_activadas_desde_encendido: null,
  maximo_dias: 30,
  fecha_minima: "2026-10-10",
  fecha_maxima: "2026-11-09",
  nota_minimo: 10,
  nota_maximo: 500,
  requisitos: { consentimiento_publicado: true, terminal_activa: true },
  alarma: { activa: false, nivel: null, codigo: null, mensaje: null },
};

export const ESTADO_ENCENDIDO = {
  ...ESTADO_APAGADO,
  activo: true,
  estado: "encendido",
  motivo: null,
  hasta: "2026-10-25T05:59:59Z",
  hasta_fecha: "2026-10-24",
  encendido_por_nombre: "Carlos Ruiz",
  encendido_en: "2026-10-10T15:30:00Z",
  altas_activadas_desde_encendido: 3,
};

export function estadoApi(extra: Record<string, unknown> = {}) {
  return { ...ESTADO_ENCENDIDO, ...extra };
}

export const ALARMA_SIN_RESPALDO = {
  activa: true,
  nivel: "atender",
  codigo: "sin_respaldo_de_la_funcion",
  mensaje: "Se detectó un cambio hecho fuera de esta pantalla; el interruptor quedó apagado. Avisa a Sistemas.",
};

export const ALARMA_FUERA_DE_LA_FUNCION = {
  activa: true,
  nivel: "atender",
  codigo: "cambio_fuera_de_la_funcion",
  mensaje: "El interruptor está encendido pero su último cambio no quedó registrado como debe. Avisa a Sistemas.",
};

export const ALARMA_REVISAR = {
  activa: true,
  nivel: "revisar",
  codigo: "vigencias_inconsistentes",
  mensaje: "El ajuste está en un estado inconsistente; el interruptor quedó apagado. Avisa a Sistemas.",
};
