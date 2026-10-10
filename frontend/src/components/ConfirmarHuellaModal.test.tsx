import { fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { ConfirmarHuellaModal } from "./ConfirmarHuellaModal";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));

const ALTA = { id: 77, persona_nombre: "Luis Ramírez", employee_no: 1041 };
const NOTA = "TI enroló el índice derecho en el menú del aparato.";

function respuesta(status: number, cuerpo: unknown = {}) {
  return Promise.resolve(new Response(JSON.stringify(cuerpo), { status }));
}

function cuerpoPost(): { nota: string } {
  return JSON.parse(vi.mocked(apiFetch).mock.calls.at(-1)![1]!.body as string);
}

const confirmar = () => screen.getByRole("button", { name: /confirmar que vi la huella/i });

describe("ConfirmarHuellaModal", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("explica que se atesta haber visto la huella, que no se deshace y no pide datos personales", () => {
    render(<ConfirmarHuellaModal terminalId={1} terminalNombre="Entrada principal" alta={ALTA} onCerrar={vi.fn()} />);
    expect(screen.getByRole("dialog", { name: /confirmar huella/i })).toBeInTheDocument();
    expect(screen.getByText(/atestiguando que viste la huella de esta persona en el menú del aparato/i)).toBeInTheDocument();
    expect(screen.getByText(/no se puede deshacer/i)).toBeInTheDocument();
    expect(screen.getByText(/dar de baja el alta y crear una nueva/i)).toBeInTheDocument();
    expect(screen.getByText(/no escribas datos personales, solo cómo verificaste la huella/i)).toBeInTheDocument();
    expect(screen.getByText(/luis ramírez/i)).toBeInTheDocument();
    expect(screen.getByText(/entrada principal/i)).toBeInTheDocument();
  });

  it("el contador cuenta lo escrito y muestra el mínimo", async () => {
    render(<ConfirmarHuellaModal terminalId={1} alta={ALTA} onCerrar={vi.fn()} />);
    expect(screen.getByText("0 / 500 · mínimo 10")).toBeInTheDocument();
    await userEvent.type(screen.getByLabelText(/nota/i), "hola");
    expect(screen.getByText("4 / 500 · mínimo 10")).toBeInTheDocument();
  });

  it("nota de menos de 10 caracteres: error de campo y no llama al servidor; 9 no, 10 sí", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(201, { id: 77 }));
    render(<ConfirmarHuellaModal terminalId={1} alta={ALTA} onCerrar={vi.fn()} />);
    fireEvent.change(screen.getByLabelText(/nota/i), { target: { value: "123456789" } });
    await userEvent.click(confirmar());
    expect(screen.getByText(/al menos 10 caracteres/i)).toBeInTheDocument();
    expect(apiFetch).not.toHaveBeenCalled();
    fireEvent.change(screen.getByLabelText(/nota/i), { target: { value: "1234567890" } });
    await userEvent.click(confirmar());
    expect(await screen.findByRole("heading", { name: /huella confirmada/i })).toBeInTheDocument();
  });

  it("los espacios no cuentan: 10 espacios + 3 letras no alcanza", async () => {
    render(<ConfirmarHuellaModal terminalId={1} alta={ALTA} onCerrar={vi.fn()} />);
    fireEvent.change(screen.getByLabelText(/nota/i), { target: { value: "          abc" } });
    await userEvent.click(confirmar());
    expect(apiFetch).not.toHaveBeenCalled();
  });

  it("envía POST a …/huella-confirmada sólo con la nota saneada y avisa del éxito", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(201, { id: 77, estado: "activo", huella_evidencia: "manual" }));
    const onCerrar = vi.fn();
    render(<ConfirmarHuellaModal terminalId={1} alta={ALTA} onCerrar={onCerrar} />);
    await userEvent.type(screen.getByLabelText(/nota/i), `   ${NOTA}   `);
    await userEvent.click(confirmar());

    expect(await screen.findByText(/huella confirmada por una persona \(sin conteo\)/i)).toBeInTheDocument();
    expect(vi.mocked(apiFetch).mock.calls[0][0]).toBe("/api/terminales/1/usuarios/77/huella-confirmada");
    expect(vi.mocked(apiFetch).mock.calls[0][1]?.method).toBe("POST");
    expect(cuerpoPost()).toEqual({ nota: NOTA });
    await userEvent.click(screen.getByRole("button", { name: /cerrar/i }));
    expect(onCerrar).toHaveBeenCalledWith(true);
  });

  it("mientras envía bloquea el modal y evita el doble envío", async () => {
    vi.mocked(apiFetch).mockImplementation(() => new Promise<Response>(() => {}));
    render(<ConfirmarHuellaModal terminalId={1} alta={ALTA} onCerrar={vi.fn()} />);
    await userEvent.type(screen.getByLabelText(/nota/i), NOTA);
    await userEvent.click(confirmar());
    expect(screen.getByRole("button", { name: /confirmando/i })).toBeDisabled();
    expect(screen.getByRole("button", { name: /volver/i })).toBeDisabled();
    expect(screen.getByLabelText(/nota/i)).toBeDisabled();
    expect(apiFetch).toHaveBeenCalledTimes(1);
  });

  it("409 (el alta ya no está en Esperando huella): detail fijo, conserva la nota y ofrece Actualizar lista", async () => {
    const detail = "El movimiento no es válido para el estado actual del alta.";
    vi.mocked(apiFetch).mockReturnValue(respuesta(409, { detail }));
    const onCerrar = vi.fn();
    render(<ConfirmarHuellaModal terminalId={1} alta={ALTA} onCerrar={onCerrar} />);
    await userEvent.type(screen.getByLabelText(/nota/i), NOTA);
    await userEvent.click(confirmar());
    expect(await screen.findByRole("alert")).toHaveTextContent(detail);
    expect(screen.getByLabelText(/nota/i)).toHaveValue(NOTA);
    await userEvent.click(screen.getByRole("button", { name: /actualizar lista/i }));
    expect(onCerrar).toHaveBeenCalledWith(true);
  });

  it.each([
    [422, "No puedes confirmar tu propia huella; la confirma otra persona con permiso.", "No puedes confirmar tu propia huella; la confirma otra persona con permiso."],
    [422, "Quien asignó el alta no puede confirmar su huella; la confirma otra persona con permiso.", "Quien asignó el alta no puede confirmar su huella; la confirma otra persona con permiso."],
    [422, "La nota de la confirmación debe tener entre 10 y 500 caracteres.", "La nota de la confirmación debe tener entre 10 y 500 caracteres."],
    [403, "No tienes permiso para esta acción.", "No tienes permiso para esta acción."],
    [500, "stack interno", "No se pudo completar. Inténtalo de nuevo."],
  ])("error %i: %s", async (status, detail, esperado) => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(status, { detail }));
    render(<ConfirmarHuellaModal terminalId={1} alta={ALTA} onCerrar={vi.fn()} />);
    await userEvent.type(screen.getByLabelText(/nota/i), NOTA);
    await userEvent.click(confirmar());
    const alerta = await screen.findByRole("alert");
    expect(alerta).toHaveTextContent(esperado);
    expect(alerta).not.toHaveTextContent(/stack interno/);
    expect(confirmar()).toBeEnabled();
    expect(screen.queryByRole("button", { name: /actualizar lista/i })).not.toBeInTheDocument();
  });

  it("Volver y Escape cierran sin refrescar", async () => {
    const onCerrar = vi.fn();
    render(<ConfirmarHuellaModal terminalId={1} alta={ALTA} onCerrar={onCerrar} />);
    await userEvent.click(screen.getByRole("button", { name: /volver/i }));
    expect(onCerrar).toHaveBeenCalledWith(false);
    onCerrar.mockClear();
    fireEvent(screen.getByRole("dialog"), new Event("cancel", { cancelable: true }));
    expect(onCerrar).toHaveBeenCalledWith(false);
  });
});
