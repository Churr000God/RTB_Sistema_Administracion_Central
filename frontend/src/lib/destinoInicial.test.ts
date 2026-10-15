import { describe, expect, it } from "vitest";

import { destinoInicial, RUTA_INICIO } from "./destinoInicial";

const SIN_NADA = { puede_ver_modulo_1: false, puede_ver_modulo_2: false, puede_ver_modulo_3: false };

describe("destinoInicial", () => {
  it("sesión que no cargó: comportamiento histórico (/personas)", () => {
    expect(destinoInicial(null)).toBe("/personas");
  });

  it("módulo 1 manda a Personas aunque vea otros", () => {
    expect(destinoInicial({ ...SIN_NADA, puede_ver_modulo_1: true, puede_ver_modulo_3: true })).toBe("/personas");
  });

  it("sin módulo 1 sigue el orden del sidebar: Estructura, luego Tiempo, luego Terminales", () => {
    expect(destinoInicial({ ...SIN_NADA, puede_ver_modulo_2: true, puede_ver_modulo_3: true })).toBe("/estructura/areas");
    expect(destinoInicial({ ...SIN_NADA, puede_ver_modulo_3: true, puede_ver_terminales: true })).toBe("/tiempo/asignacion-jornada");
    expect(destinoInicial({ ...SIN_NADA, puede_ver_terminales: true })).toBe("/tiempo/terminales");
  });

  it("ningún módulo (o banderas ausentes): /inicio", () => {
    expect(destinoInicial(SIN_NADA)).toBe(RUTA_INICIO);
    expect(destinoInicial({ ...SIN_NADA, puede_ver_terminales: false })).toBe("/inicio");
    expect(RUTA_INICIO).toBe("/inicio");
  });
});
