import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import erroresPy from "../../../backend/app/errores.py?raw";
import correccionesPy from "../../../backend/app/routers/correcciones.py?raw";
import { AvisoBloqueoCorreccion } from "./AvisoBloqueoCorreccion";

const MENSAJE_TRAMO =
  "Esta marca ya forma parte de un tramo: no se puede corregir su hora desde aquí. Revisa el día.";
const MENSAJE_CERRADO =
  "Este día ya está cerrado: la corrección no se refleja en las horas. Revisa el día.";
const MENSAJE_PENDIENTE =
  "Esta marca es de un día ya cerrado: no se corrige ni se resuelve a mano. Revisa el día (o, si el día ya está revisado, descarta la marca tardía).";

describe("AvisoBloqueoCorreccion", () => {
  it("deja Corregir visible pero inactivo (aria-disabled, sigue en el orden de tab)", () => {
    render(<AvisoBloqueoCorreccion motivo="en_tramo" hrefDia="/tiempo/dias" />);
    const boton = screen.getByRole("button", { name: "Corregir" });
    expect(boton).toHaveAttribute("aria-disabled", "true");
    expect(boton).not.toBeDisabled();
  });

  it("no navega ni hace nada al hacer clic en Corregir", async () => {
    render(<AvisoBloqueoCorreccion motivo="en_tramo" hrefDia="/tiempo/dias" />);
    await userEvent.click(screen.getByRole("button", { name: "Corregir" }));
    expect(screen.queryByRole("link", { name: "Corregir" })).not.toBeInTheDocument();
  });

  it.each([
    ["en_tramo", "Ya está en un tramo", MENSAJE_TRAMO],
    ["en_tramo_cerrado", "Día / tramo cerrado", MENSAJE_CERRADO],
    ["dia_cerrado_pendiente", "Marca tardía · día cerrado", MENSAJE_PENDIENTE],
  ] as const)("%s: etiqueta corta y mensaje fijo del backend", async (motivo, etiqueta, mensaje) => {
    render(<AvisoBloqueoCorreccion motivo={motivo} hrefDia="/tiempo/dias" />);
    expect(screen.getByText(etiqueta)).toBeInTheDocument();
    expect(screen.getByText(mensaje)).not.toBeVisible();

    const porque = screen.getByRole("button", { name: "¿Por qué?" });
    expect(porque).toHaveAttribute("aria-expanded", "false");
    await userEvent.click(porque);

    expect(porque).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByText(mensaje)).toBeVisible();
    expect(screen.getByRole("button", { name: "Corregir" })).toHaveAccessibleDescription(mensaje);
  });

  it("ofrece Ir a revisar el día con el href recibido", () => {
    render(<AvisoBloqueoCorreccion motivo="en_tramo_cerrado" hrefDia="/tiempo/dias" />);
    expect(screen.getByRole("link", { name: /ir a revisar el día/i })).toHaveAttribute(
      "href",
      "/tiempo/dias",
    );
  });

  it("dia_cerrado_pendiente suma el enlace a Excepciones; los otros motivos no", () => {
    const { rerender } = render(
      <AvisoBloqueoCorreccion motivo="dia_cerrado_pendiente" hrefDia="/tiempo/dias" />,
    );
    expect(screen.getByRole("link", { name: /ver en excepciones/i })).toHaveAttribute(
      "href",
      "/tiempo/excepciones",
    );
    rerender(<AvisoBloqueoCorreccion motivo="en_tramo" hrefDia="/tiempo/dias" />);
    expect(screen.queryByRole("link", { name: /ver en excepciones/i })).not.toBeInTheDocument();
  });

  it("un motivo desconocido (valor nuevo del backend) no rompe la pantalla: usa el aviso de tramo", () => {
    render(
      <AvisoBloqueoCorreccion
        motivo={"motivo_nuevo" as unknown as "en_tramo"}
        hrefDia="/tiempo/dias"
      />,
    );
    expect(screen.getByRole("button", { name: "Corregir" })).toHaveAttribute("aria-disabled", "true");
    expect(screen.getByRole("link", { name: /ir a revisar el día/i })).toBeInTheDocument();
  });

  it("Corregir bloqueado no navega ni dispara nada al activarse", async () => {
    const alHacerClic = vi.fn();
    const { container } = render(
      <div onClick={alHacerClic}>
        <AvisoBloqueoCorreccion motivo="en_tramo" hrefDia="/tiempo/dias" />
      </div>,
    );
    const boton = screen.getByRole("button", { name: "Corregir" });
    expect(boton).toHaveAttribute("type", "button");
    expect(boton.closest("a")).toBeNull();
    expect(boton.closest("form")).toBeNull();
    await userEvent.click(boton);
    await userEvent.type(boton, "{Enter}");
    // sólo burbujea el clic (sin handler propio); no hay enlaces extra a un corregir
    expect(container.querySelector("a[href*=\"corregir\"]")).toBeNull();
  });

  describe("los mensajes siguen siendo los del backend", () => {
    const backend = [erroresPy, correccionesPy]
      .join("\n")
      // Los textos largos están partidos en literales de Python concatenados: se juntan.
      .replace(/"\s*\n\s*"/g, "");

    it.each([MENSAJE_TRAMO, MENSAJE_CERRADO, MENSAJE_PENDIENTE])("existe en el backend: %s", (mensaje) => {
      expect(backend).toContain(mensaje);
    });
  });
});
