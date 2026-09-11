import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { calcularHorasSemana, DetalleJornadaAsignada, type PatronDia } from "./DetalleJornadaAsignada";

// Ejemplo real del usuario: lun-jue 8am-9pm con 6h de comida -> 7h netas/día (no 13h); viernes
// 8am-8pm con 60min -> 11h; sábado 8am-5pm con 60min -> 8h. Total: 4*7 + 11 + 8 = 47h.
const PATRON_EJEMPLO: PatronDia[] = [
  { dia_semana: "lunes", hora_entrada: "08:00:00", hora_salida: "21:00:00", minutos_comida: 360 },
  { dia_semana: "martes", hora_entrada: "08:00:00", hora_salida: "21:00:00", minutos_comida: 360 },
  { dia_semana: "miercoles", hora_entrada: "08:00:00", hora_salida: "21:00:00", minutos_comida: 360 },
  { dia_semana: "jueves", hora_entrada: "08:00:00", hora_salida: "21:00:00", minutos_comida: 360 },
  { dia_semana: "viernes", hora_entrada: "08:00:00", hora_salida: "20:00:00", minutos_comida: 60 },
  { dia_semana: "sabado", hora_entrada: "08:00:00", hora_salida: "17:00:00", minutos_comida: 60 },
];

describe("calcularHorasSemana", () => {
  it("suma (salida - entrada) - comida por día -- ejemplo real del usuario da 47h", () => {
    expect(calcularHorasSemana(PATRON_EJEMPLO)).toBe(47);
  });

  it("lunes-jueves 8am-9pm con 6h de comida da 7h netas por día, no 13h", () => {
    const soloLunes: PatronDia[] = [
      { dia_semana: "lunes", hora_entrada: "08:00:00", hora_salida: "21:00:00", minutos_comida: 360 },
    ];
    expect(calcularHorasSemana(soloLunes)).toBe(7);
  });

  it("viernes 8am-8pm con 60min de comida da 11h", () => {
    const soloViernes: PatronDia[] = [
      { dia_semana: "viernes", hora_entrada: "08:00:00", hora_salida: "20:00:00", minutos_comida: 60 },
    ];
    expect(calcularHorasSemana(soloViernes)).toBe(11);
  });

  it("sábado 8am-5pm con 60min de comida da 8h", () => {
    const soloSabado: PatronDia[] = [
      { dia_semana: "sabado", hora_entrada: "08:00:00", hora_salida: "17:00:00", minutos_comida: 60 },
    ];
    expect(calcularHorasSemana(soloSabado)).toBe(8);
  });

  it("patrón vacío da 0h", () => {
    expect(calcularHorasSemana([])).toBe(0);
  });
});

describe("DetalleJornadaAsignada", () => {
  it("muestra el total de horas semanales calculado del patrón, no el campo (siempre NULL en la DB)", () => {
    render(
      <DetalleJornadaAsignada
        estado="listo"
        jornada={{
          tipo_jornada: "normal",
          vigente_desde: "2026-01-01",
          horas_semanales_calculadas: null,
          patron_semanal: PATRON_EJEMPLO,
        }}
      />,
    );

    expect(screen.getByText(/≈ 47\.0 h\/semana esperadas/)).toBeInTheDocument();
  });
});
