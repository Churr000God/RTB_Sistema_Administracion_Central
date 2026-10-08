import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { Modal } from "./Modal";

describe("Modal", () => {
  it("abre un <dialog> modal con título accesible y su contenido", () => {
    const abrir = vi.spyOn(HTMLDialogElement.prototype, "showModal");
    render(
      <Modal titulo="Asignar persona" onCancelar={vi.fn()}>
        <p>Contenido</p>
      </Modal>,
    );
    expect(abrir).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("dialog", { name: "Asignar persona" })).toBeInTheDocument();
    expect(screen.getByText("Contenido")).toBeInTheDocument();
    abrir.mockRestore();
  });

  it("Escape pide cancelar y deja el cierre al padre (el evento queda cancelado)", () => {
    const onCancelar = vi.fn();
    render(
      <Modal titulo="T" onCancelar={onCancelar}>
        <p>x</p>
      </Modal>,
    );
    const evento = new Event("cancel", { cancelable: true });
    fireEvent(screen.getByRole("dialog"), evento);
    expect(onCancelar).toHaveBeenCalledTimes(1);
    expect(evento.defaultPrevented).toBe(true);
  });

  it("bloqueado (enviando) ignora Escape", () => {
    const onCancelar = vi.fn();
    render(
      <Modal titulo="T" bloqueado onCancelar={onCancelar}>
        <p>x</p>
      </Modal>,
    );
    const evento = new Event("cancel", { cancelable: true });
    fireEvent(screen.getByRole("dialog"), evento);
    expect(onCancelar).not.toHaveBeenCalled();
    expect(evento.defaultPrevented).toBe(true);
  });

  it("al desmontarse cierra el <dialog> nativo, para que el foco vuelva al botón que lo abrió", () => {
    const cerrar = vi.spyOn(HTMLDialogElement.prototype, "close");
    const { unmount } = render(
      <Modal titulo="T" onCancelar={vi.fn()}>
        <p>x</p>
      </Modal>,
    );
    unmount();
    expect(cerrar).toHaveBeenCalled();
    cerrar.mockRestore();
  });

  it("describe el diálogo con la descripción cuando se da", () => {
    render(
      <Modal titulo="T" descripcion="Se asigna a la terminal" onCancelar={vi.fn()}>
        <p>x</p>
      </Modal>,
    );
    expect(screen.getByRole("dialog")).toHaveAccessibleDescription("Se asigna a la terminal");
  });
});
