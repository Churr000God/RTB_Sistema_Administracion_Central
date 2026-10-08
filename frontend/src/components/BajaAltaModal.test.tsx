import { fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { BajaAltaModal } from "./BajaAltaModal";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));

const ALTA = { id: 77, persona_nombre: "Luis Ramírez", employee_no: 1041 };
const MOTIVO = "La persona revocó su consentimiento.";

function respuesta(status: number, cuerpo: unknown = {}) {
  return Promise.resolve(new Response(typeof cuerpo === "string" ? cuerpo : JSON.stringify(cuerpo), { status }));
}

function cuerpoPost(): { motivo: string } {
  return JSON.parse(vi.mocked(apiFetch).mock.calls.at(-1)![1]!.body as string);
}

describe("BajaAltaModal", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("cancelar alta: título, advertencia y botón que nombran la consecuencia", () => {
    render(<BajaAltaModal terminalId={1} alta={ALTA} accion="cancelar_alta" onCerrar={vi.fn()} />);
    expect(screen.getByRole("dialog", { name: /cancelar alta/i })).toBeInTheDocument();
    expect(screen.getByText(/el alta se cancela y el usuario se borra del aparato/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /cancelar el alta/i })).toBeInTheDocument();
    expect(screen.getByText(/luis ramírez/i)).toBeInTheDocument();
  });

  it("dar de baja: advierte que es irreversible y que borra la huella del aparato", () => {
    render(<BajaAltaModal terminalId={1} alta={ALTA} accion="dar_de_baja" onCerrar={vi.fn()} />);
    expect(screen.getByRole("dialog", { name: /dar de baja/i })).toBeInTheDocument();
    expect(screen.getByText(/borrará el usuario y sus huellas del aparato/i)).toBeInTheDocument();
    expect(screen.getByText(/irreversible/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /dar de baja definitivamente/i })).toBeInTheDocument();
  });

  it("el motivo es obligatorio (mín. 10, máx. 500) y se muestra el contador", async () => {
    render(<BajaAltaModal terminalId={1} alta={ALTA} accion="dar_de_baja" onCerrar={vi.fn()} />);
    const campo = screen.getByLabelText(/motivo/i);
    expect(campo).toBeRequired();
    expect(campo).toHaveAttribute("maxlength", "500");
    expect(screen.getByText("0 / 500 · mínimo 10")).toBeInTheDocument();
    await userEvent.type(campo, "corto");
    expect(screen.getByText("5 / 500 · mínimo 10")).toBeInTheDocument();
  });

  it.each(["", "   ", "corto", "         x"])("motivo %j no llega al servidor y marca el campo", async (texto) => {
    render(<BajaAltaModal terminalId={1} alta={ALTA} accion="dar_de_baja" onCerrar={vi.fn()} />);
    if (texto) fireEvent.change(screen.getByLabelText(/motivo/i), { target: { value: texto } });
    await userEvent.click(screen.getByRole("button", { name: /dar de baja definitivamente/i }));
    expect(apiFetch).not.toHaveBeenCalled();
    expect(screen.getByText(/escribe el motivo de la baja \(al menos 10 caracteres\)/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/motivo/i)).toHaveAttribute("aria-invalid", "true");
  });

  it("más de 500 caracteres (saltando maxLength) tampoco se envía; 500 exactos sí", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(201, { id: 77 }));
    render(<BajaAltaModal terminalId={1} alta={ALTA} accion="dar_de_baja" onCerrar={vi.fn()} />);
    fireEvent.change(screen.getByLabelText(/motivo/i), { target: { value: "a".repeat(501) } });
    await userEvent.click(screen.getByRole("button", { name: /dar de baja definitivamente/i }));
    expect(apiFetch).not.toHaveBeenCalled();
    fireEvent.change(screen.getByLabelText(/motivo/i), { target: { value: "a".repeat(500) } });
    await userEvent.click(screen.getByRole("button", { name: /dar de baja definitivamente/i }));
    expect(await screen.findByText(/baja solicitada/i)).toBeInTheDocument();
  });

  it("envía POST a …/baja con el motivo y avisa que quedó pendiente de baja", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(201, { id: 77, estado: "pendiente_baja" }));
    const onCerrar = vi.fn();
    render(<BajaAltaModal terminalId={1} alta={ALTA} accion="dar_de_baja" onCerrar={onCerrar} />);
    await userEvent.type(screen.getByLabelText(/motivo/i), `  ${MOTIVO}  `);
    await userEvent.click(screen.getByRole("button", { name: /dar de baja definitivamente/i }));

    expect(await screen.findByText(/baja solicitada/i)).toBeInTheDocument();
    expect(vi.mocked(apiFetch).mock.calls[0][0]).toBe("/api/terminales/1/usuarios/77/baja");
    expect(vi.mocked(apiFetch).mock.calls[0][1]?.method).toBe("POST");
    expect(cuerpoPost()).toEqual({ motivo: MOTIVO });
    expect(screen.getByText(/pendiente de baja/i)).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: /cerrar/i }));
    expect(onCerrar).toHaveBeenCalledWith(true);
  });

  it("mientras envía bloquea el modal y evita el doble envío", async () => {
    vi.mocked(apiFetch).mockImplementation(() => new Promise<Response>(() => {}));
    render(<BajaAltaModal terminalId={1} alta={ALTA} accion="dar_de_baja" onCerrar={vi.fn()} />);
    await userEvent.type(screen.getByLabelText(/motivo/i), MOTIVO);
    await userEvent.click(screen.getByRole("button", { name: /dar de baja definitivamente/i }));
    expect(screen.getByRole("button", { name: /solicitando baja/i })).toBeDisabled();
    expect(screen.getByRole("button", { name: /volver/i })).toBeDisabled();
    expect(screen.getByLabelText(/motivo/i)).toBeDisabled();
    expect(apiFetch).toHaveBeenCalledTimes(1);
  });

  it("409 (estado inválido): detail fijo del backend y Actualizar lista", async () => {
    const detail = "El movimiento no es válido para el estado actual del alta.";
    vi.mocked(apiFetch).mockReturnValue(respuesta(409, { detail }));
    const onCerrar = vi.fn();
    render(<BajaAltaModal terminalId={1} alta={ALTA} accion="dar_de_baja" onCerrar={onCerrar} />);
    await userEvent.type(screen.getByLabelText(/motivo/i), MOTIVO);
    await userEvent.click(screen.getByRole("button", { name: /dar de baja definitivamente/i }));
    expect(await screen.findByRole("alert")).toHaveTextContent(detail);
    expect(screen.getByLabelText(/motivo/i)).toHaveValue(MOTIVO);
    await userEvent.click(screen.getByRole("button", { name: /actualizar lista/i }));
    expect(onCerrar).toHaveBeenCalledWith(true);
  });

  it.each([
    [403, "No tienes permiso para esta acción.", "No tienes permiso para esta acción."],
    [422, "El motivo de la baja debe tener entre 10 y 500 caracteres.", "El motivo de la baja debe tener entre 10 y 500 caracteres."],
    [503, "stack interno", "Servicio no disponible; reintenta."],
    [500, "stack interno", "No se pudo completar. Inténtalo de nuevo."],
  ])("error %i: %s", async (status, detail, esperado) => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(status, { detail }));
    render(<BajaAltaModal terminalId={1} alta={ALTA} accion="dar_de_baja" onCerrar={vi.fn()} />);
    await userEvent.type(screen.getByLabelText(/motivo/i), MOTIVO);
    await userEvent.click(screen.getByRole("button", { name: /dar de baja definitivamente/i }));
    const alerta = await screen.findByRole("alert");
    expect(alerta).toHaveTextContent(esperado);
    expect(alerta).not.toHaveTextContent(/stack interno/);
    expect(screen.getByRole("button", { name: /dar de baja definitivamente/i })).toBeEnabled();
  });

  it("Volver y Escape cierran sin refrescar", async () => {
    const onCerrar = vi.fn();
    render(<BajaAltaModal terminalId={1} alta={ALTA} accion="cancelar_alta" onCerrar={onCerrar} />);
    await userEvent.click(screen.getByRole("button", { name: /volver/i }));
    expect(onCerrar).toHaveBeenCalledWith(false);
    onCerrar.mockClear();
    fireEvent(screen.getByRole("dialog"), new Event("cancel", { cancelable: true }));
    expect(onCerrar).toHaveBeenCalledWith(false);
  });
});
