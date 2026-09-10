import { describe, expect, it } from "vitest";
import { descripcionTramoAntiguedad, etiquetaTramoAntiguedad } from "./tramosAntiguedad";

describe("etiquetaTramoAntiguedad", () => {
  it("ventana par (6): corta la mitad exacta", () => {
    expect(etiquetaTramoAntiguedad("reciente", 6)).toBe("0-3m");
    expect(etiquetaTramoAntiguedad("media", 6)).toBe("3-6m");
    expect(etiquetaTramoAntiguedad("fuera_ventana", 6)).toBe("6+m");
  });

  it("ventana impar (5): usa piso entero, igual que el backend", () => {
    expect(etiquetaTramoAntiguedad("reciente", 5)).toBe("0-2m");
    expect(etiquetaTramoAntiguedad("media", 5)).toBe("2-5m");
    expect(etiquetaTramoAntiguedad("fuera_ventana", 5)).toBe("5+m");
  });
});

describe("descripcionTramoAntiguedad", () => {
  it("ventana impar (5): describe con la mitad en piso entero", () => {
    expect(descripcionTramoAntiguedad("reciente", 5)).toBe("Deuda de los últimos 2 meses.");
    expect(descripcionTramoAntiguedad("media", 5)).toBe(
      "Deuda de entre 2 y 5 meses de antigüedad.",
    );
    expect(descripcionTramoAntiguedad("fuera_ventana", 5)).toBe(
      "Deuda de más de 5 meses -- fuera de la ventana de resolución del banco de horas.",
    );
  });
});
