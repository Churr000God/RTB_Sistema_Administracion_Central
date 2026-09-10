export type TipoMovimiento = "alta" | "suspension" | "reactivacion" | "baja_definitiva";

export type Estado = "activo" | "suspension" | "baja_definitiva";

export type Movimiento = {
  id: string;
  persona_id: string;
  tipo_movimiento: TipoMovimiento;
  fecha_efectiva: string;
  motivo: string | null;
  documento_ref?: string | null;
  registrado_por?: string | null;
  registrado_por_nombre?: string | null;
};

export type Transicion = Movimiento & {
  estadoAnterior: Estado | null;
  estadoNuevo: Estado;
};

export type Resumen = {
  total: number;
  conteos: Record<TipoMovimiento, number>;
  diasEnSuspension: number;
};

// Espeja exactamente personas.fn_bitacora_sincroniza_persona (db/ddl/05_personas_estructura.sql)
// — cualquier cambio ahí debe reflejarse acá.
const ESTADO_RESULTANTE: Record<TipoMovimiento, Estado> = {
  alta: "activo",
  suspension: "suspension",
  reactivacion: "activo",
  baja_definitiva: "baja_definitiva",
};

function ordenarPorFecha(movimientos: Movimiento[]): Movimiento[] {
  return [...movimientos].sort(
    (a, b) => new Date(a.fecha_efectiva).getTime() - new Date(b.fecha_efectiva).getTime()
  );
}

/**
 * Deriva estadoAnterior/estadoNuevo por movimiento, ordenando ascendente. El primer movimiento
 * (siempre "alta" en la práctica, ya que fn_caller_activo/el alta de persona lo garantiza) no
 * tiene estado anterior — se pinta sin flecha, sin inventar un pseudo-estado "Sin registro".
 */
export function derivarTransiciones(movimientos: Movimiento[]): Transicion[] {
  const ordenados = ordenarPorFecha(movimientos);
  return ordenados.map((movimiento, indice) => ({
    ...movimiento,
    estadoAnterior: indice === 0 ? null : ESTADO_RESULTANTE[ordenados[indice - 1].tipo_movimiento],
    estadoNuevo: ESTADO_RESULTANTE[movimiento.tipo_movimiento],
  }));
}

function diferenciaDias(inicio: Date, fin: Date): number {
  const ms = fin.getTime() - inicio.getTime();
  return Math.max(0, Math.round(ms / (1000 * 60 * 60 * 24)));
}

/**
 * Total, conteos por tipo, y días en suspensión emparejando entradas suspension→reactivacion
 * consecutivas. Un tramo sin reactivación (todavía suspendida) cuenta hasta hoy. Una
 * baja_definitiva cierra cualquier suspensión abierta sin contarla como reactivación.
 */
export function resumenBitacora(movimientos: Movimiento[]): Resumen {
  const ordenados = ordenarPorFecha(movimientos);

  const conteos: Record<TipoMovimiento, number> = {
    alta: 0,
    suspension: 0,
    reactivacion: 0,
    baja_definitiva: 0,
  };
  for (const movimiento of ordenados) {
    conteos[movimiento.tipo_movimiento] += 1;
  }

  let diasEnSuspension = 0;
  let inicioSuspension: Date | null = null;
  for (const movimiento of ordenados) {
    if (movimiento.tipo_movimiento === "suspension") {
      inicioSuspension = new Date(movimiento.fecha_efectiva);
    } else if (movimiento.tipo_movimiento === "reactivacion" && inicioSuspension) {
      diasEnSuspension += diferenciaDias(inicioSuspension, new Date(movimiento.fecha_efectiva));
      inicioSuspension = null;
    } else if (movimiento.tipo_movimiento === "baja_definitiva") {
      inicioSuspension = null;
    }
  }
  if (inicioSuspension) {
    diasEnSuspension += diferenciaDias(inicioSuspension, new Date());
  }

  return { total: ordenados.length, conteos, diasEnSuspension };
}
