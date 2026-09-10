import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { Card } from "./Card";

describe("Card", () => {
  it("renderiza un div con la clase tarjeta-resumen", () => {
    render(<Card>Contenido</Card>);
    expect(screen.getByText("Contenido")).toHaveClass("tarjeta-resumen");
  });

  it("acepta className extra sin perder la clase base", () => {
    render(<Card className="tarjeta-inmutable">Contenido</Card>);
    expect(screen.getByText("Contenido")).toHaveClass("tarjeta-resumen", "tarjeta-inmutable");
  });

  it("as='form' renderiza un <form> y conserva onSubmit", () => {
    const onSubmit = vi.fn((e) => e.preventDefault());
    render(
      <Card as="form" onSubmit={onSubmit} data-testid="tarjeta-form">
        <button type="submit">Guardar</button>
      </Card>
    );
    const form = screen.getByTestId("tarjeta-form");
    expect(form.tagName).toBe("FORM");
    expect(form).toHaveClass("tarjeta-resumen");
  });
});
