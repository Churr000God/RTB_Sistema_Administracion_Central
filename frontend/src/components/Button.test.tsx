import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ArrowRight } from "lucide-react";

import { Button } from "./Button";

describe("Button", () => {
  it("renderiza un <button> con las clases base y dispara onClick", async () => {
    const onClick = vi.fn();
    render(
      <Button type="button" onClick={onClick}>
        Guardar
      </Button>
    );
    const boton = screen.getByRole("button", { name: "Guardar" });
    expect(boton).toHaveClass("boton-con-icono");
    expect(boton).not.toHaveClass("boton-primario");
    boton.click();
    expect(onClick).toHaveBeenCalledOnce();
  });

  it("variante primario agrega boton-primario", () => {
    render(
      <Button variante="primario" type="submit">
        Registrar
      </Button>
    );
    expect(screen.getByRole("button", { name: "Registrar" })).toHaveClass(
      "boton-con-icono",
      "boton-primario"
    );
  });

  it("con href, renderiza un <a> en vez de un <button>", () => {
    render(
      <Button href="/estructura/areas" variante="primario">
        Nueva área
      </Button>
    );
    const enlace = screen.getByRole("link", { name: "Nueva área" });
    expect(enlace).toHaveAttribute("href", "/estructura/areas");
    expect(enlace).toHaveClass("boton-con-icono", "boton-primario");
  });

  it("con icono, lo agrega como decorativo (aria-hidden)", () => {
    render(
      <Button type="submit" icono={ArrowRight}>
        Registrar
      </Button>
    );
    const boton = screen.getByRole("button", { name: "Registrar" });
    expect(boton.querySelector("svg")).toHaveAttribute("aria-hidden", "true");
  });

  it("tamanoIcono ajusta el tamaño del icono decorativo (enlaces secundarios más chicos)", () => {
    render(
      <Button type="submit" icono={ArrowRight} tamanoIcono={14}>
        Registrar
      </Button>
    );
    expect(screen.getByRole("button", { name: "Registrar" }).querySelector("svg")).toHaveAttribute(
      "width",
      "14"
    );
  });

  it("respeta disabled", () => {
    render(
      <Button type="submit" disabled>
        Registrar
      </Button>
    );
    expect(screen.getByRole("button", { name: "Registrar" })).toBeDisabled();
  });

  it("cargando deshabilita el botón de verdad (no sólo visualmente) y muestra el spinner", () => {
    render(
      <Button type="submit" icono={ArrowRight} cargando>
        Registrar
      </Button>
    );
    const boton = screen.getByRole("button", { name: "Registrar" });
    expect(boton).toBeDisabled();
    expect(boton.querySelector("svg")).toHaveClass("icono-girando");
  });

  it("cargando con textoCargando reemplaza el texto del botón (no el ícono, que siempre es el spinner)", () => {
    render(
      <Button type="submit" cargando textoCargando="Guardando…">
        Guardar
      </Button>
    );
    const boton = screen.getByRole("button", { name: "Guardando…" });
    expect(boton.querySelector("svg.icono-girando")).toBeInTheDocument();
  });

  it("sin cargando, no dispara el estado disabled ni muestra el spinner", () => {
    render(
      <Button type="submit" icono={ArrowRight}>
        Registrar
      </Button>
    );
    const boton = screen.getByRole("button", { name: "Registrar" });
    expect(boton).not.toBeDisabled();
    expect(boton.querySelector("svg")).not.toHaveClass("icono-girando");
  });
});
