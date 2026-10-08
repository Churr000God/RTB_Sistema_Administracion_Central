export type DatosDia = { diaId?: number | null; personaId?: string | null; fecha?: string | null };

// "Ir a revisar el día": DiasPage lee dia_id o persona_id/desde/hasta de la URL y los manda a
// GET /api/dias. Con dia_id cae en la fila exacta; sin él (el día aún no existe como fila) se
// acota por persona y fecha; sin datos suficientes queda en Días sin filtro.
export function hrefRevisarDia({ diaId, personaId, fecha }: DatosDia): string {
  if (diaId != null && Number.isInteger(diaId) && diaId > 0) return `/tiempo/dias?dia_id=${diaId}`;
  if (personaId && fecha) {
    const params = new URLSearchParams({ persona_id: personaId, desde: fecha, hasta: fecha });
    return `/tiempo/dias?${params.toString()}`;
  }
  return "/tiempo/dias";
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ENTERO_POSITIVO = /^[1-9]\d*$/;

function esFechaISO(valor: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(valor)) return false;
  const fecha = new Date(`${valor}T00:00:00Z`);
  return !Number.isNaN(fecha.getTime()) && fecha.toISOString().slice(0, 10) === valor;
}

export type FiltrosDiasUrl = { diaId: string; personaId: string; desde: string; hasta: string };

// Lee y VALIDA los filtros que DiasPage acepta por URL (dia_id entero positivo, persona_id UUID,
// desde/hasta fecha ISO real). Todo lo que no pase se ignora ("" = sin filtro): la URL la puede
// escribir cualquiera y no debe viajar a GET /api/dias ni mostrar un aviso engañoso.
export function leerFiltrosDiasDeUrl(search: string): FiltrosDiasUrl {
  const params = new URLSearchParams(search);
  const diaId = params.get("dia_id") ?? "";
  const personaId = params.get("persona_id") ?? "";
  const desde = params.get("desde") ?? "";
  const hasta = params.get("hasta") ?? "";
  return {
    diaId: ENTERO_POSITIVO.test(diaId) && Number.isSafeInteger(Number(diaId)) ? diaId : "",
    personaId: UUID.test(personaId) ? personaId.toLowerCase() : "",
    desde: esFechaISO(desde) ? desde : "",
    hasta: esFechaISO(hasta) ? hasta : "",
  };
}
