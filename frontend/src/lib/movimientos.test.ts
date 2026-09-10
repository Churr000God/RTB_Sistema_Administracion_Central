import { describe, expect, it } from "vitest";

import { derivarTransiciones, resumenBitacora, type Movimiento } from "./movimientos";

function mov(overrides: Partial<Movimiento>): Movimiento {
  return {
    id: "sin-id",
    persona_id: "p1",
    tipo_movimiento: "alta",
    fecha_efectiva: "2024-01-01T00:00:00Z",
    motivo: null,
    ...overrides,
  };
}

describe("derivarTransiciones", () => {
  it("el primer movimiento (alta) no tiene estado anterior y su estado nuevo es activo", () => {
    const [primera] = derivarTransiciones([
      mov({ id: "1", tipo_movimiento: "alta", fecha_efectiva: "2024-01-01T00:00:00Z" }),
    ]);

    expect(primera.estadoAnterior).toBeNull();
    expect(primera.estadoNuevo).toBe("activo");
  });

  it("deriva la secuencia completa alta → suspension → reactivacion → baja_definitiva", () => {
    const transiciones = derivarTransiciones([
      mov({ id: "1", tipo_movimiento: "alta", fecha_efectiva: "2024-01-01T00:00:00Z" }),
      mov({ id: "2", tipo_movimiento: "suspension", fecha_efectiva: "2024-02-01T00:00:00Z" }),
      mov({ id: "3", tipo_movimiento: "reactivacion", fecha_efectiva: "2024-03-01T00:00:00Z" }),
      mov({ id: "4", tipo_movimiento: "baja_definitiva", fecha_efectiva: "2024-04-01T00:00:00Z" }),
    ]);

    expect(transiciones.map((t) => [t.estadoAnterior, t.estadoNuevo])).toEqual([
      [null, "activo"],
      ["activo", "suspension"],
      ["suspension", "activo"],
      ["activo", "baja_definitiva"],
    ]);
  });

  it("ordena internamente aunque los movimientos lleguen desordenados", () => {
    const transiciones = derivarTransiciones([
      mov({ id: "3", tipo_movimiento: "reactivacion", fecha_efectiva: "2024-03-01T00:00:00Z" }),
      mov({ id: "1", tipo_movimiento: "alta", fecha_efectiva: "2024-01-01T00:00:00Z" }),
      mov({ id: "2", tipo_movimiento: "suspension", fecha_efectiva: "2024-02-01T00:00:00Z" }),
    ]);

    expect(transiciones.map((t) => t.id)).toEqual(["1", "2", "3"]);
    expect(transiciones.map((t) => t.estadoNuevo)).toEqual(["activo", "suspension", "activo"]);
  });

  it("un array vacío no rompe: devuelve un array vacío", () => {
    expect(derivarTransiciones([])).toEqual([]);
  });
});

describe("resumenBitacora", () => {
  it("un array vacío no rompe: total 0, conteos en 0, 0 días en suspensión", () => {
    const resumen = resumenBitacora([]);
    expect(resumen.total).toBe(0);
    expect(resumen.diasEnSuspension).toBe(0);
    expect(resumen.conteos).toEqual({ alta: 0, suspension: 0, reactivacion: 0, baja_definitiva: 0 });
  });

  it("cuenta el total y los movimientos por tipo", () => {
    const resumen = resumenBitacora([
      mov({ id: "1", tipo_movimiento: "alta", fecha_efectiva: "2024-01-01T00:00:00Z" }),
      mov({ id: "2", tipo_movimiento: "suspension", fecha_efectiva: "2024-02-01T00:00:00Z" }),
      mov({ id: "3", tipo_movimiento: "reactivacion", fecha_efectiva: "2024-03-01T00:00:00Z" }),
    ]);

    expect(resumen.total).toBe(3);
    expect(resumen.conteos).toEqual({ alta: 1, suspension: 1, reactivacion: 1, baja_definitiva: 0 });
  });

  it("calcula días en suspensión con un tramo cerrado (suspension → reactivacion)", () => {
    const resumen = resumenBitacora([
      mov({ id: "1", tipo_movimiento: "alta", fecha_efectiva: "2024-01-01T00:00:00Z" }),
      mov({ id: "2", tipo_movimiento: "suspension", fecha_efectiva: "2024-02-01T00:00:00Z" }),
      mov({ id: "3", tipo_movimiento: "reactivacion", fecha_efectiva: "2024-02-11T00:00:00Z" }),
    ]);

    expect(resumen.diasEnSuspension).toBe(10);
  });

  it("suma varios tramos cerrados", () => {
    const resumen = resumenBitacora([
      mov({ id: "1", tipo_movimiento: "alta", fecha_efectiva: "2024-01-01T00:00:00Z" }),
      mov({ id: "2", tipo_movimiento: "suspension", fecha_efectiva: "2024-02-01T00:00:00Z" }),
      mov({ id: "3", tipo_movimiento: "reactivacion", fecha_efectiva: "2024-02-06T00:00:00Z" }),
      mov({ id: "4", tipo_movimiento: "suspension", fecha_efectiva: "2024-03-01T00:00:00Z" }),
      mov({ id: "5", tipo_movimiento: "reactivacion", fecha_efectiva: "2024-03-08T00:00:00Z" }),
    ]);

    expect(resumen.diasEnSuspension).toBe(12); // 5 + 7
  });

  it("un tramo abierto (suspension sin reactivación) cuenta hasta hoy", () => {
    const hace5Dias = new Date();
    hace5Dias.setDate(hace5Dias.getDate() - 5);

    const resumen = resumenBitacora([
      mov({ id: "1", tipo_movimiento: "alta", fecha_efectiva: "2024-01-01T00:00:00Z" }),
      mov({ id: "2", tipo_movimiento: "suspension", fecha_efectiva: hace5Dias.toISOString() }),
    ]);

    expect(resumen.diasEnSuspension).toBeGreaterThanOrEqual(4);
    expect(resumen.diasEnSuspension).toBeLessThanOrEqual(6);
  });

  it("baja_definitiva cierra una suspensión abierta sin contarla como reactivación", () => {
    const resumen = resumenBitacora([
      mov({ id: "1", tipo_movimiento: "alta", fecha_efectiva: "2024-01-01T00:00:00Z" }),
      mov({ id: "2", tipo_movimiento: "suspension", fecha_efectiva: "2024-02-01T00:00:00Z" }),
      mov({ id: "3", tipo_movimiento: "baja_definitiva", fecha_efectiva: "2024-02-11T00:00:00Z" }),
    ]);

    // el tramo queda cerrado por la baja, pero no se cuenta como día en suspensión
    // porque no hay una regla de negocio que lo pida — sólo se cuentan tramos con reactivación
    // o el tramo abierto final.
    expect(resumen.diasEnSuspension).toBe(0);
    expect(resumen.conteos.baja_definitiva).toBe(1);
  });
});
