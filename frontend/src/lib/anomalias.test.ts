import { describe, expect, it } from "vitest";

import { describirHallazgo, esRespuestaAnomalias } from "./anomalias";

describe("describirHallazgo", () => {
  it("rechazos definitivos: código y total", () => {
    expect(describirHallazgo("rechazos_definitivos", { codigo: "no_enrolado", total: 4 })).toBe("no_enrolado: 4 rechazos");
  });

  it.each([
    [{ tipo: "llave_antigua", antiguedad_meses: 13 }, "Llave del puente con 13 meses de antigüedad (rotar)"],
    [{ tipo: "llave_sin_uso", antiguedad_dias: 3 }, "Llave del puente sin uso desde hace 3 días"],
    [{ tipo: "traslape_abierto", dias_abierto: 9 }, "Traslape de llaves abierto hace 9 días"],
    [{ tipo: "cambio_de_ip", hace_dias: 2 }, "Cambio de IP del puente hace 2 días"],
    [{ tipo: "algo_nuevo" }, "Hallazgo de credenciales"],
  ])("credenciales %j", (ejemplo, esperado) => {
    expect(describirHallazgo("credenciales", ejemplo)).toBe(esperado);
  });

  it("inconsistencias: persona suspendida con alta activa, baja definitiva, e inexistente", () => {
    expect(describirHallazgo("inconsistencias_de_baja", { persona_nombre: "Ana", estado_persona: "suspension", estado_alta: "activo" })).toBe(
      "Ana · suspendida, pero su alta sigue Activo",
    );
    expect(describirHallazgo("inconsistencias_de_baja", { persona_nombre: "Ana", estado_persona: "baja_definitiva", estado_alta: "esperando_huella" })).toContain("en baja definitiva");
    expect(describirHallazgo("inconsistencias_de_baja", { persona_nombre: null, estado_persona: "inexistente", estado_alta: "activo" })).toBe(
      "La persona ya no existe y su alta sigue Activo",
    );
  });

  it("valores ausentes se pintan como guion, no como undefined/null", () => {
    const texto = describirHallazgo("altas_recientes", {});
    expect(texto).not.toMatch(/undefined|null/);
    expect(texto).toContain("—");
  });

  it("una categoría desconocida no rompe", () => {
    expect(describirHallazgo("categoria_nueva", { x: 1 })).toBe("Hallazgo sin descripción");
  });

  it("nunca imprime el objeto crudo: identificadores que el backend no manda tampoco salen", () => {
    const texto = describirHallazgo("marcas_posteriores_a_baja", { persona_nombre: "Ana", persona_id: "abc-secreto", marca_en: "2026-10-05T18:02:00Z", baja_confirmada_en: "2026-10-03T15:00:00Z" });
    expect(texto).not.toContain("abc-secreto");
  });
});

describe("esRespuestaAnomalias", () => {
  it("exige la lista de categorías", () => {
    expect(esRespuestaAnomalias({ categorias: [] })).toBe(true);
    expect(esRespuestaAnomalias({ categorias: "x" })).toBe(false);
    expect(esRespuestaAnomalias(null)).toBe(false);
    expect(esRespuestaAnomalias([])).toBe(false);
  });
});
