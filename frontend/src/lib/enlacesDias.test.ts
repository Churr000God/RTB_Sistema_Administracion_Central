import { describe, expect, it } from "vitest";

import { hrefRevisarDia, leerFiltrosDiasDeUrl } from "./enlacesDias";

const UUID = "3f2b8c1e-9a4d-4e6f-8b1a-2c3d4e5f6a7b";

describe("hrefRevisarDia", () => {
  it("con dia_id cae en la fila exacta", () => {
    expect(hrefRevisarDia({ diaId: 7, personaId: "p1", fecha: "2026-10-05" })).toBe("/tiempo/dias?dia_id=7");
  });

  it("sin dia_id (el día aún no existe como fila) filtra por persona y fecha", () => {
    expect(hrefRevisarDia({ diaId: null, personaId: "p1", fecha: "2026-10-05" })).toBe(
      "/tiempo/dias?persona_id=p1&desde=2026-10-05&hasta=2026-10-05",
    );
  });

  it("sin datos suficientes degrada a Días sin filtro", () => {
    expect(hrefRevisarDia({})).toBe("/tiempo/dias");
    expect(hrefRevisarDia({ personaId: "p1" })).toBe("/tiempo/dias");
  });

  it.each([0, -3, 1.5, Number.NaN, Number.POSITIVE_INFINITY])("ignora un dia_id inválido (%s)", (diaId) => {
    expect(hrefRevisarDia({ diaId })).toBe("/tiempo/dias");
    expect(hrefRevisarDia({ diaId, personaId: "p1", fecha: "2026-10-05" })).toBe(
      "/tiempo/dias?persona_id=p1&desde=2026-10-05&hasta=2026-10-05",
    );
  });

  it("codifica los valores que arma (nada de inyectar parámetros)", () => {
    const href = hrefRevisarDia({ personaId: "a&dia_id=9", fecha: "2026-10-05" });
    expect(new URL(href, "http://x").searchParams.get("persona_id")).toBe("a&dia_id=9");
    expect(new URL(href, "http://x").searchParams.has("dia_id")).toBe(false);
  });
});

describe("leerFiltrosDiasDeUrl", () => {
  it("acepta dia_id entero positivo, persona_id UUID y fechas ISO reales", () => {
    expect(
      leerFiltrosDiasDeUrl(`?dia_id=21&persona_id=${UUID.toUpperCase()}&desde=2026-10-05&hasta=2026-10-06`),
    ).toEqual({ diaId: "21", personaId: UUID, desde: "2026-10-05", hasta: "2026-10-06" });
  });

  it.each(["abc", "0", "-1", "1.5", "1e3", "21; DROP", ""])("descarta dia_id inválido (%j)", (valor) => {
    expect(leerFiltrosDiasDeUrl(`?dia_id=${encodeURIComponent(valor)}`).diaId).toBe("");
  });

  it.each(["persona-1", "123", "../etc", ""])("descarta persona_id que no es UUID (%j)", (valor) => {
    expect(leerFiltrosDiasDeUrl(`?persona_id=${encodeURIComponent(valor)}`).personaId).toBe("");
  });

  it.each(["hoy", "2026-13-01", "2026-02-30", "05/10/2026", ""])("descarta fecha inválida (%j)", (valor) => {
    const f = leerFiltrosDiasDeUrl(`?desde=${encodeURIComponent(valor)}&hasta=${encodeURIComponent(valor)}`);
    expect(f.desde).toBe("");
    expect(f.hasta).toBe("");
  });

  it("sin parámetros devuelve todo vacío", () => {
    expect(leerFiltrosDiasDeUrl("")).toEqual({ diaId: "", personaId: "", desde: "", hasta: "" });
  });
});
