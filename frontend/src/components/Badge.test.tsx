import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { Badge } from "./Badge";

describe("Badge", () => {
  it("variante exito renderiza insignia insignia--exito", () => {
    render(<Badge variante="exito">Activo</Badge>);
    expect(screen.getByText("Activo")).toHaveClass("insignia", "insignia--exito");
  });

  it("bloque agrega insignia--bloque", () => {
    render(
      <Badge variante="aviso" bloque>
        En revisión
      </Badge>
    );
    expect(screen.getByText("En revisión")).toHaveClass("insignia--bloque");
  });

  it("estado renderiza la familia insignia-estado en vez de insignia", () => {
    render(<Badge estado="activo">Activo</Badge>);
    const badge = screen.getByText("Activo");
    expect(badge).toHaveClass("insignia-estado", "activo");
    expect(badge).not.toHaveClass("insignia");
  });

  it("estado baja_definitiva", () => {
    render(<Badge estado="baja_definitiva">Inactivo</Badge>);
    expect(screen.getByText("Inactivo")).toHaveClass("insignia-estado", "baja_definitiva");
  });
});
