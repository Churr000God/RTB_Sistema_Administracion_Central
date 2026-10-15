import { describe, expect, it } from "vitest";

import { destinoInicial, modulosVisibles, RUTA_INICIO } from "./destinoInicial";

const SIN_NADA = { puede_ver_modulo_1: false, puede_ver_modulo_2: false, puede_ver_modulo_3: false };

describe("destinoInicial", () => {
  it("es /inicio para todos, tengan o no módulos", () => {
    expect(destinoInicial()).toBe("/inicio");
    expect(RUTA_INICIO).toBe("/inicio");
  });
});

describe("modulosVisibles", () => {
  it("en el orden del sidebar y sólo con un true explícito", () => {
    expect(modulosVisibles({ puede_ver_modulo_1: true, puede_ver_modulo_2: true, puede_ver_modulo_3: true, puede_ver_terminales: true })).toEqual([
      { etiqueta: "Personas y Usuarios", href: "/personas" },
      { etiqueta: "Estructura organizacional", href: "/estructura/areas" },
      { etiqueta: "Tiempo", href: "/tiempo/asignacion-jornada" },
      { etiqueta: "Terminales", href: "/tiempo/terminales" },
    ]);
  });

  it("ningún módulo (o banderas ausentes) da una lista vacía", () => {
    expect(modulosVisibles(SIN_NADA)).toEqual([]);
    expect(modulosVisibles({ ...SIN_NADA, puede_ver_terminales: false })).toEqual([]);
    expect(modulosVisibles({} as never)).toEqual([]);
  });

  it("sólo los que sí ve", () => {
    expect(modulosVisibles({ ...SIN_NADA, puede_ver_modulo_3: true })).toEqual([{ etiqueta: "Tiempo", href: "/tiempo/asignacion-jornada" }]);
  });
});
