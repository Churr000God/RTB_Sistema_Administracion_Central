// Conversión entre el valor nativo de <input type="week"> ("YYYY-Www", semana ISO 8601) y la
// fecha del lunes de esa semana — el backend de tope legal (GET /api/tope-legal/exceso-semanal)
// pide "semana_de" como esa fecha de lunes en ISO ("YYYY-MM-DD"), no el string de semana crudo.
//
// Regla ISO 8601: la semana 1 de un año es la que contiene el primer jueves de enero (equivale a
// la que contiene el 4 de enero). Por eso la semana 1 puede empezar en diciembre del año anterior,
// y por qué algunos años tienen 53 semanas en vez de 52.

const PATRON_SEMANA_ISO = /^(\d{4})-W(\d{2})$/;

function pad(n: number): string {
  return String(n).padStart(2, "0");
}

function aFechaISO(fecha: Date): string {
  return `${fecha.getFullYear()}-${pad(fecha.getMonth() + 1)}-${pad(fecha.getDate())}`;
}

// 1 (lunes) .. 7 (domingo) — Date.getDay() da 0 (domingo) .. 6 (sábado).
function diaSemanaIso(fecha: Date): number {
  const dia = fecha.getDay();
  return dia === 0 ? 7 : dia;
}

/**
 * Convierte el valor de un <input type="week"> ("YYYY-Www") a la fecha del lunes de esa semana,
 * como string "YYYY-MM-DD". Devuelve null si el formato no es válido (semana fuera de 01-53,
 * o el string no matchea "YYYY-Www").
 */
export function semanaIsoALunes(valorSemana: string): string | null {
  const coincidencia = PATRON_SEMANA_ISO.exec(valorSemana);
  if (!coincidencia) return null;

  const anio = Number(coincidencia[1]);
  const semana = Number(coincidencia[2]);
  if (semana < 1 || semana > 53) return null;

  // El 4 de enero siempre cae en la semana 1 (regla ISO) — desde ahí se ubica su lunes y se
  // suman (semana - 1) semanas completas.
  const cuatroDeEnero = new Date(anio, 0, 4);
  const lunesSemana1 = new Date(cuatroDeEnero);
  lunesSemana1.setDate(cuatroDeEnero.getDate() - (diaSemanaIso(cuatroDeEnero) - 1));

  const lunes = new Date(lunesSemana1);
  lunes.setDate(lunesSemana1.getDate() + (semana - 1) * 7);

  return aFechaISO(lunes);
}

/**
 * Convierte una fecha (se asume lunes, pero funciona para cualquier día de esa semana) al valor
 * de <input type="week"> ("YYYY-Www") de la semana ISO que la contiene. Usada para precargar el
 * selector con la semana actual.
 */
export function fechaASemanaIso(fecha: Date): string {
  // Método del "jueves más cercano": el año ISO de una fecha es el año del jueves de su semana.
  const jueves = new Date(fecha);
  jueves.setDate(fecha.getDate() + (4 - diaSemanaIso(fecha)));
  const anioIso = jueves.getFullYear();

  const cuatroDeEnero = new Date(anioIso, 0, 4);
  const lunesSemana1 = new Date(cuatroDeEnero);
  lunesSemana1.setDate(cuatroDeEnero.getDate() - (diaSemanaIso(cuatroDeEnero) - 1));

  const diasDesdeSemana1 = Math.round((jueves.getTime() - lunesSemana1.getTime()) / 86_400_000);
  const semana = Math.floor(diasDesdeSemana1 / 7) + 1;

  return `${anioIso}-W${pad(semana)}`;
}

/** Lunes de la semana ISO que contiene `fecha`, como Date. */
export function lunesDeLaSemana(fecha: Date): Date {
  const lunes = new Date(fecha);
  lunes.setDate(fecha.getDate() - (diaSemanaIso(fecha) - 1));
  lunes.setHours(0, 0, 0, 0);
  return lunes;
}
