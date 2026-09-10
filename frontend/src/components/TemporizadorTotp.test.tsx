import { act, cleanup, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { TemporizadorTotp } from "./TemporizadorTotp";

describe("TemporizadorTotp", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
    cleanup();
  });

  it("calcula el restante anclado al reloj Unix (epoch % 30 === 6 → 00:24)", () => {
    vi.setSystemTime(new Date(30_000 * 100 + 6_000));
    render(<TemporizadorTotp />);

    expect(screen.getByText("00:24")).toBeInTheDocument();
  });

  it("recicla al cruzar el múltiplo de 30 segundos, sin seguir bajando a 00", () => {
    vi.setSystemTime(new Date(30_000 * 100 + 29_000)); // restante = 1
    render(<TemporizadorTotp />);
    expect(screen.getByText("00:01")).toBeInTheDocument();

    act(() => {
      vi.advanceTimersByTime(2000); // cruza el múltiplo de 30s sin saltar el reloj a mano
    });

    const texto = screen.getByText(/00:\d{2}/).textContent ?? "";
    const restante = Number(texto.split(":")[1]);
    expect(restante).toBeGreaterThan(20); // recicló a un valor alto, no continuó hacia negativos
  });

  it("limpia el intervalo al desmontar", () => {
    vi.setSystemTime(new Date(30_000 * 100));
    const limpiarSpy = vi.spyOn(window, "clearInterval");
    const { unmount } = render(<TemporizadorTotp />);
    unmount();

    expect(limpiarSpy).toHaveBeenCalled();
  });
});
