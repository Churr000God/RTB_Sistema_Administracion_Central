import { describe, expect, it } from "vitest";

import { aFechaISO, grillaDelMes, semanaDeDias } from "./calendario";

function aplanar<T>(semanas: T[][]): T[] {
  return semanas.flat();
}

function verificarInvariantes(semanas: ReturnType<typeof grillaDelMes>) {
  for (const semana of semanas) {
    expect(semana).toHaveLength(7);
    const [lunes] = semana;
    const fechaLunes = new Date(`${lunes.fecha}T00:00:00`);
    // getDay(): 0=domingo..6=sábado. Lunes = 1.
    expect(fechaLunes.getDay()).toBe(1);
  }
  const dias = aplanar(semanas);
  for (let i = 1; i < dias.length; i++) {
    const anterior = new Date(`${dias[i - 1].fecha}T00:00:00`);
    const actual = new Date(`${dias[i].fecha}T00:00:00`);
    const diffDias = Math.round((actual.getTime() - anterior.getTime()) / 86_400_000);
    expect(diffDias).toBe(1); // consecutivos, sin huecos ni saltos
  }
}

describe("grillaDelMes", () => {
  it("mes que calza exacto lunes-domingo (febrero 2021) — sin relleno, 4 semanas", () => {
    const semanas = grillaDelMes(new Date(2021, 1, 15));
    verificarInvariantes(semanas);
    expect(semanas).toHaveLength(4);
    const dias = aplanar(semanas);
    expect(dias[0].fecha).toBe("2021-02-01");
    expect(dias[dias.length - 1].fecha).toBe("2021-02-28");
    expect(dias.every((d) => d.delMesActual)).toBe(true);
  });

  it("mes con relleno sólo al final (septiembre 2025)", () => {
    const semanas = grillaDelMes(new Date(2025, 8, 15));
    verificarInvariantes(semanas);
    expect(semanas).toHaveLength(5);
    const dias = aplanar(semanas);
    expect(dias[0].fecha).toBe("2025-09-01");
    expect(dias[0].delMesActual).toBe(true);
    expect(dias[dias.length - 1].fecha).toBe("2025-10-05");
    expect(dias[dias.length - 1].delMesActual).toBe(false);
    // últimos 5 días (1-5 oct) son relleno; todo lo anterior es de septiembre.
    const relleno = dias.slice(-5);
    expect(relleno.every((d) => !d.delMesActual && d.fecha.startsWith("2025-10"))).toBe(true);
    expect(dias.slice(0, -5).every((d) => d.delMesActual)).toBe(true);
  });

  it("mes con relleno en ambos extremos (marzo 2026)", () => {
    const semanas = grillaDelMes(new Date(2026, 2, 15));
    verificarInvariantes(semanas);
    expect(semanas).toHaveLength(6);
    const dias = aplanar(semanas);
    expect(dias[0].fecha).toBe("2026-02-23");
    expect(dias[0].delMesActual).toBe(false);
    expect(dias[dias.length - 1].fecha).toBe("2026-04-05");
    expect(dias[dias.length - 1].delMesActual).toBe(false);

    const rellenoInicio = dias.slice(0, 6); // 23-28 feb
    expect(rellenoInicio.every((d) => !d.delMesActual && d.fecha.startsWith("2026-02"))).toBe(true);
    const rellenoFin = dias.slice(-5); // 1-5 abr
    expect(rellenoFin.every((d) => !d.delMesActual && d.fecha.startsWith("2026-04"))).toBe(true);
    const marzo = dias.slice(6, -5);
    expect(marzo).toHaveLength(31);
    expect(marzo.every((d) => d.delMesActual && d.fecha.startsWith("2026-03"))).toBe(true);
  });

  it("febrero bisiesto (2024) incluye el 29", () => {
    const semanas = grillaDelMes(new Date(2024, 1, 10));
    verificarInvariantes(semanas);
    const dias = aplanar(semanas);
    const diasDeFebrero = dias.filter((d) => d.delMesActual);
    expect(diasDeFebrero).toHaveLength(29);
    expect(diasDeFebrero.some((d) => d.fecha === "2024-02-29")).toBe(true);
    expect(dias[0].fecha).toBe("2024-01-29");
    expect(dias[dias.length - 1].fecha).toBe("2024-03-03");
  });

  it("febrero no bisiesto (2025) tiene 28 días, sin 29", () => {
    const semanas = grillaDelMes(new Date(2025, 1, 10));
    verificarInvariantes(semanas);
    const dias = aplanar(semanas);
    const diasDeFebrero = dias.filter((d) => d.delMesActual);
    expect(diasDeFebrero).toHaveLength(28);
    expect(diasDeFebrero.some((d) => d.fecha === "2025-02-29")).toBe(false);
    expect(dias[0].fecha).toBe("2025-01-27");
    expect(dias[dias.length - 1].fecha).toBe("2025-03-02");
  });

  it("no corrige por UTC — funciona igual sin importar la hora del ancla", () => {
    const semanasMedianoche = grillaDelMes(new Date(2026, 2, 1, 0, 0, 0));
    const semanasNoche = grillaDelMes(new Date(2026, 2, 1, 23, 59, 59));
    expect(aplanar(semanasMedianoche).map((d) => d.fecha)).toEqual(
      aplanar(semanasNoche).map((d) => d.fecha),
    );
  });
});

describe("semanaDeDias", () => {
  it("devuelve los 7 días Lun-Dom de la semana del ancla", () => {
    const dias = semanaDeDias(new Date(2026, 8, 9)); // miércoles 2026-09-09
    expect(dias).toHaveLength(7);
    expect(dias[0].fecha).toBe("2026-09-07");
    expect(dias[6].fecha).toBe("2026-09-13");
    expect(new Date(`${dias[0].fecha}T00:00:00`).getDay()).toBe(1);
  });

  it("da la misma semana sin importar qué día de esa semana sea el ancla", () => {
    const desdeMartes = semanaDeDias(new Date(2026, 8, 8));
    const desdeDomingo = semanaDeDias(new Date(2026, 8, 13));
    expect(desdeMartes.map((d) => d.fecha)).toEqual(desdeDomingo.map((d) => d.fecha));
  });

  it("semana a caballo de dos meses — delMesActual distingue el mes del ancla", () => {
    // 2026-03-01 es domingo -> su semana es 2026-02-23 (lun) a 2026-03-01 (dom).
    const anclaEnMarzo = new Date(2026, 2, 1);
    const dias = semanaDeDias(anclaEnMarzo);
    expect(dias.map((d) => d.fecha)).toEqual([
      "2026-02-23",
      "2026-02-24",
      "2026-02-25",
      "2026-02-26",
      "2026-02-27",
      "2026-02-28",
      "2026-03-01",
    ]);
    // El ancla es de marzo -> sólo el domingo (03-01) cuenta como "del mes actual".
    expect(dias.filter((d) => d.delMesActual).map((d) => d.fecha)).toEqual(["2026-03-01"]);

    const anclaEnFebrero = new Date(2026, 1, 23);
    const diasDesdeFebrero = semanaDeDias(anclaEnFebrero);
    expect(diasDesdeFebrero.filter((d) => d.delMesActual).map((d) => d.fecha)).toEqual([
      "2026-02-23",
      "2026-02-24",
      "2026-02-25",
      "2026-02-26",
      "2026-02-27",
      "2026-02-28",
    ]);
  });
});

describe("aFechaISO", () => {
  it("formatea con ceros a la izquierda", () => {
    expect(aFechaISO(new Date(2026, 0, 5))).toBe("2026-01-05");
  });
});
