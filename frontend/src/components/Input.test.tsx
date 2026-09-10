import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { Input } from "./Input";

describe("Input", () => {
  it("asocia label e input por id/htmlFor", () => {
    render(<Input id="nombre_area" label="Nombre del área" name="nombre_area" />);
    expect(screen.getByLabelText("Nombre del área")).toBeInTheDocument();
  });

  it("sin ayuda ni error, no agrega aria-describedby", () => {
    render(<Input id="nombre_area" label="Nombre del área" name="nombre_area" />);
    expect(screen.getByLabelText("Nombre del área")).not.toHaveAttribute("aria-describedby");
  });

  it("con ayuda, la enlaza vía aria-describedby", () => {
    render(
      <Input
        id="nombre_area"
        label="Nombre del área"
        name="nombre_area"
        ayuda="Debe ser único, ej. Comercial."
      />
    );
    const campo = screen.getByLabelText("Nombre del área");
    const ayuda = screen.getByText("Debe ser único, ej. Comercial.");
    expect(ayuda).toHaveAttribute("id", "nombre_area-ayuda");
    expect(campo).toHaveAttribute("aria-describedby", "nombre_area-ayuda");
  });

  it("con error, lo enlaza vía aria-describedby y marca aria-invalid", () => {
    render(
      <Input
        id="nombre_area"
        label="Nombre del área"
        name="nombre_area"
        error="Ya existe un área con ese nombre."
      />
    );
    const campo = screen.getByLabelText("Nombre del área");
    const error = screen.getByRole("alert");
    expect(error).toHaveTextContent("Ya existe un área con ese nombre.");
    expect(campo).toHaveAttribute("aria-describedby", "nombre_area-error");
    expect(campo).toHaveAttribute("aria-invalid", "true");
  });

  it("pasa props nativas (required, maxLength, defaultValue) al <input>", () => {
    render(
      <Input
        id="nombre_area"
        label="Nombre del área"
        name="nombre_area"
        required
        maxLength={100}
        defaultValue="Comercial"
      />
    );
    const campo = screen.getByLabelText("Nombre del área");
    expect(campo).toBeRequired();
    expect(campo).toHaveAttribute("maxlength", "100");
    expect(campo).toHaveValue("Comercial");
  });
});
