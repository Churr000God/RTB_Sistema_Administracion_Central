// Construcción de grillas de calendario (mensual y semanal) para las vistas de Días festivos —
// complementa semanaIso.ts, reusando su lunesDeLaSemana en vez de reimplementar la regla ISO.
// Todo con getters locales de Date (getFullYear/getMonth/getDate/setDate) — nunca
// toISOString(), que serializa en UTC y corre un día en cualquier timezone detrás de UTC.

import { lunesDeLaSemana } from "./semanaIso";

export type DiaGrilla = {
  fecha: string; // "YYYY-MM-DD", hora local
  diaDelMes: number;
  delMesActual: boolean;
};

function pad(n: number): string {
  return String(n).padStart(2, "0");
}

export function aFechaISO(fecha: Date): string {
  return `${fecha.getFullYear()}-${pad(fecha.getMonth() + 1)}-${pad(fecha.getDate())}`;
}

function armarDia(cursor: Date, anioAncla: number, mesAncla: number): DiaGrilla {
  return {
    fecha: aFechaISO(cursor),
    diaDelMes: cursor.getDate(),
    delMesActual: cursor.getFullYear() === anioAncla && cursor.getMonth() === mesAncla,
  };
}

/**
 * Semanas completas (Lun-Dom) que cubren el mes de `ancla`, con relleno de los días del mes
 * anterior/siguiente que completan la primera y última semana. Cada semana tiene exactamente 7
 * días; el primer día de la grilla siempre es lunes.
 */
export function grillaDelMes(ancla: Date): DiaGrilla[][] {
  const anio = ancla.getFullYear();
  const mes = ancla.getMonth();

  const primerDiaMes = new Date(anio, mes, 1);
  const ultimoDiaMes = new Date(anio, mes + 1, 0); // día 0 del mes siguiente = último del actual, cubre bisiesto sin caso especial

  const inicio = lunesDeLaSemana(primerDiaMes);
  const finExclusivo = lunesDeLaSemana(ultimoDiaMes);
  finExclusivo.setDate(finExclusivo.getDate() + 7);

  const dias: DiaGrilla[] = [];
  const cursor = new Date(inicio);
  while (cursor.getTime() < finExclusivo.getTime()) {
    dias.push(armarDia(cursor, anio, mes));
    cursor.setDate(cursor.getDate() + 1);
  }

  const semanas: DiaGrilla[][] = [];
  for (let i = 0; i < dias.length; i += 7) {
    semanas.push(dias.slice(i, i + 7));
  }
  return semanas;
}

/** Los 7 días (Lun-Dom) de la semana ISO que contiene `ancla`. */
export function semanaDeDias(ancla: Date): DiaGrilla[] {
  const anio = ancla.getFullYear();
  const mes = ancla.getMonth();
  const inicio = lunesDeLaSemana(ancla);

  const dias: DiaGrilla[] = [];
  const cursor = new Date(inicio);
  for (let i = 0; i < 7; i++) {
    dias.push(armarDia(cursor, anio, mes));
    cursor.setDate(cursor.getDate() + 1);
  }
  return dias;
}

/** Hoy en hora local, "YYYY-MM-DD" -- nunca toISOString() (ver cabecera del archivo). */
export function hoyISO(): string {
  return aFechaISO(new Date());
}

/** `fechaISO` es estrictamente posterior a `hoy` (por defecto, hoy real). Comparación lexicográfica
 * -- válida porque ambas son "YYYY-MM-DD". */
export function esFutura(fechaISO: string, hoy: string = hoyISO()): boolean {
  return fechaISO > hoy;
}

/** `fechaISO` es hoy o anterior. */
export function esPasadaOhoy(fechaISO: string, hoy: string = hoyISO()): boolean {
  return fechaISO <= hoy;
}

/** `fechaISO` desplazada `dias` (positivo o negativo) vía getters/setters locales de Date --
 * cruza fin de mes/año y bisiestos sin caso especial. */
export function sumarDiasISO(fechaISO: string, dias: number): string {
  const [anio, mes, dia] = fechaISO.split("-").map(Number);
  const fecha = new Date(anio, mes - 1, dia);
  fecha.setDate(fecha.getDate() + dias);
  return aFechaISO(fecha);
}

const TIME_ZONE_NEGOCIO = "America/Mexico_City";

/**
 * Caso inverso a los helpers de arriba: éstos manipulan fechas de CALENDARIO ("qué día es hoy",
 * sin hora) con getters locales, a propósito para no depender de ningún TZ fijo. Esta función
 * formatea un INSTANTE real (un timestamp UTC de la DB -- una marca, un movimiento, una corrida
 * de batch) para mostrarlo siempre en hora de México, sin importar el TZ del navegador/entorno
 * donde corre. `toLocaleString`/`toLocaleTimeString` sin `timeZone` explícito usan el TZ del
 * sistema -- eso hacía que un mismo timestamp se viera distinto según el dispositivo (mismo bug
 * ya corregido en backend con `ZoneInfo("America/Mexico_City")`, ver CLAUDE.md 2026-09-11).
 */
export function formatearHoraMexico(fecha: Date, opciones: Intl.DateTimeFormatOptions): string {
  return fecha.toLocaleString("es-MX", { ...opciones, timeZone: TIME_ZONE_NEGOCIO });
}
