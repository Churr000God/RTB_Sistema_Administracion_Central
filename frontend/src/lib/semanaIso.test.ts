import { describe, expect, it } from "vitest";

import { fechaASemanaIso, lunesDeLaSemana, semanaIsoALunes } from "./semanaIso";

describe("semanaIsoALunes", () => {
  it("semana 1 que empieza el mismo 1 de enero (2024, año bisiesto que arranca en lunes)", () => {
    expect(semanaIsoALunes("2024-W01")).toBe("2024-01-01");
  });

  it("semana 1 que empieza en diciembre del año anterior (Jan 1 cae miércoles)", () => {
    expect(semanaIsoALunes("2025-W01")).toBe("2024-12-30");
  });

  it("semana 1 que empieza en diciembre del año anterior (Jan 1 cae jueves)", () => {
    expect(semanaIsoALunes("2026-W01")).toBe("2025-12-29");
  });

  it("semana 53 de un año con 53 semanas ISO (2020, bisiesto que arranca en miércoles)", () => {
    expect(semanaIsoALunes("2020-W53")).toBe("2020-12-28");
  });

  it("semana 53 de otro año con 53 semanas ISO (2026, arranca en jueves)", () => {
    expect(semanaIsoALunes("2026-W53")).toBe("2026-12-28");
  });

  it("semana 1 cuyo lunes cae justo el 4 de enero", () => {
    expect(semanaIsoALunes("2027-W01")).toBe("2027-01-04");
  });

  it("devuelve null con formato inválido", () => {
    expect(semanaIsoALunes("2026-13")).toBeNull();
    expect(semanaIsoALunes("no-es-una-semana")).toBeNull();
    expect(semanaIsoALunes("")).toBeNull();
  });

  it("devuelve null con número de semana fuera de rango (00 o 54)", () => {
    expect(semanaIsoALunes("2026-W00")).toBeNull();
    expect(semanaIsoALunes("2026-W54")).toBeNull();
  });
});

describe("fechaASemanaIso", () => {
  it("es la inversa de semanaIsoALunes para los mismos casos límite", () => {
    for (const semana of ["2024-W01", "2025-W01", "2026-W01", "2020-W53", "2026-W53", "2027-W01"]) {
      const lunesIso = semanaIsoALunes(semana)!;
      const lunes = new Date(`${lunesIso}T00:00:00`);
      expect(fechaASemanaIso(lunes)).toBe(semana);
    }
  });

  it("da la misma semana para cualquier día de esa semana, no sólo el lunes", () => {
    const lunes = new Date("2026-09-07T00:00:00"); // lunes real
    const domingo = new Date("2026-09-13T00:00:00"); // domingo de la misma semana ISO
    expect(fechaASemanaIso(lunes)).toBe(fechaASemanaIso(domingo));
  });
});

describe("lunesDeLaSemana", () => {
  it("devuelve el propio lunes si la fecha ya es lunes", () => {
    const lunes = new Date("2026-09-07T15:30:00");
    const resultado = lunesDeLaSemana(lunes);
    expect(resultado.getFullYear()).toBe(2026);
    expect(resultado.getMonth()).toBe(8);
    expect(resultado.getDate()).toBe(7);
  });

  it("retrocede hasta el lunes cuando la fecha es un domingo", () => {
    const domingo = new Date("2026-09-13T00:00:00");
    const resultado = lunesDeLaSemana(domingo);
    expect(resultado.getFullYear()).toBe(2026);
    expect(resultado.getMonth()).toBe(8);
    expect(resultado.getDate()).toBe(7);
  });
});
