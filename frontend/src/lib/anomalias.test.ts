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

describe("describirHallazgo: higiene (testing)", () => {
  const CLAVES = [
    "marcas_posteriores_a_baja",
    "picos_de_tasa",
    "reloj_degradado",
    "huecos_de_secuencia",
    "rechazos_definitivos",
    "credenciales",
    "inconsistencias_de_baja",
    "altas_atascadas",
    "altas_recientes",
    "reconsentimientos_pendientes",
  ];
  const SENSIBLES = { persona_id: "id-persona-secreto", employee_no: 98765, hash: "hash-secreto", sha256: "sha-secreto", ip: "10.9.8.7", ip_completa: "192.168.77.1", password: "clave-secreta" };

  it.each(CLAVES)("%s: ni persona_id, employee_no, hash ni IP aparecen aunque vengan en la entrada", (clave) => {
    const texto = describirHallazgo(clave, { ...SENSIBLES, persona_nombre: "Ana", tipo: "llave_antigua", antiguedad_meses: 13 });
    for (const secreto of ["id-persona-secreto", "98765", "hash-secreto", "sha-secreto", "10.9.8.7", "192.168.77.1", "clave-secreta"]) {
      expect(texto).not.toContain(secreto);
    }
  });

  it("picos de tasa sin persona dice «Terminal»", () => {
    expect(describirHallazgo("picos_de_tasa", { persona_nombre: null, hora: "2026-10-06T14:00:00Z", marcas: 1200, limite: 1000 })).toMatch(/^Terminal · 1200 marcas/);
  });

  it("valores vacíos o fechas inválidas se pintan como «—»", () => {
    expect(describirHallazgo("marcas_posteriores_a_baja", { persona_nombre: "Ana", marca_en: "no-es-fecha", baja_confirmada_en: null })).toBe(
      "Ana · marcó el —, después de la baja confirmada el —",
    );
    expect(describirHallazgo("huecos_de_secuencia", { desde: 1, hasta: 5, faltan: 3, fecha: "x" })).toContain("el —");
    expect(describirHallazgo("altas_recientes", { persona_nombre: "", asignada_por: undefined, creado_en: 5 })).toBe("— (asignó —) · —");
  });
});

describe("describirHallazgo · categorías 11 a 13 (sin conteo de huellas)", () => {
  it("11 huellas_inferidas_exceso: día, activaciones, desglose y límite", () => {
    const texto = describirHallazgo("huellas_inferidas_exceso", { dia: "2026-10-09", inferidas: 7, manuales: 2, activaciones: 9, limite_inferidas: 5 });
    expect(texto).toContain("9 activaciones, 7 inferidas y 2 manuales");
    expect(texto).toContain("límite de inferidas por día: 5");
  });

  it("12 inferida_sin_marcas: nombre, etiqueta de la evidencia y fecha", () => {
    const inferida = describirHallazgo("inferida_sin_marcas", { persona_nombre: "Raúl Mena", evidencia: "inferida", activada_en: "2026-09-24T15:00:00Z" });
    expect(inferida).toContain("Raúl Mena · Huella verificada en el aparato · activada");
    const manual = describirHallazgo("inferida_sin_marcas", { persona_nombre: "Elena Ríos", evidencia: "manual", activada_en: "2026-09-27T15:00:00Z" });
    expect(manual).toContain("Huella confirmada por una persona (sin conteo)");
    expect(describirHallazgo("inferida_sin_marcas", { persona_nombre: "X", evidencia: "rara", activada_en: null })).toContain("Huella activada");
  });

  it("13 asignador_confirmador: nombres como texto plano, sin interpretar HTML", () => {
    const texto = describirHallazgo("asignador_confirmador", { persona_nombre: "Luis Ramírez", confirmada_por: "<b>Carlos Ruiz</b>", confirmada_en: "2026-10-09T16:12:00Z" });
    expect(texto).toContain("Luis Ramírez · la huella la confirmó <b>Carlos Ruiz</b>, que también asignó el alta");
  });
});
