import { describe, expect, it } from "vitest";

import { etiquetaMotivo } from "./motivosRevision";

describe("etiquetaMotivo", () => {
  it("traduce un motivo conocido sin sufijo", () => {
    expect(etiquetaMotivo("persona_inactiva")).toBe("Persona inactiva");
  });

  it("cae al string crudo si el motivo no está en el catálogo", () => {
    expect(etiquetaMotivo("motivo_inventado")).toBe("motivo_inventado");
  });

  it("con sufijo concatenado (fn_ausencia_resuelve_excepcion) traduce sólo la clave y preserva el sufijo tal cual", () => {
    expect(
      etiquetaMotivo("dia_cerrado — resuelto por ausencia autorizada, carga tardía"),
    ).toBe("Día ya cerrado — resuelto por ausencia autorizada, carga tardía");
  });

  it("con sufijo pero clave desconocida deja la clave cruda y preserva el sufijo", () => {
    expect(etiquetaMotivo("motivo_inventado — resuelto por algo")).toBe(
      "motivo_inventado — resuelto por algo",
    );
  });
});
