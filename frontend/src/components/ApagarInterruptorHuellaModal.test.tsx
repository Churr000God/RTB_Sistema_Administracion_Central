import { fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { ESTADO_APAGADO } from "../testing/interruptorHuella";
import { ApagarInterruptorHuellaModal } from "./ApagarInterruptorHuellaModal";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));

function respuesta(status: number, cuerpo: unknown = {}) {
  return Promise.resolve(new Response(JSON.stringify(cuerpo), { status }));
}

function montar() {
  const props = { onActualizado: vi.fn(), onCerrar: vi.fn() };
  render(<ApagarInterruptorHuellaModal {...props} />);
  return props;
}

const apagar = () => screen.getByRole("button", { name: /apagar la activación|reintentar/i });

describe("ApagarInterruptorHuellaModal", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("explica qué pasa con las altas en «Esperando huella» y que el conteo se reinicia; la nota es opcional", () => {
    montar();
    expect(screen.getByText(/las altas que están en «esperando huella» dejan de activarse solas/i)).toBeInTheDocument();
    expect(screen.getByText(/el conteo de altas activadas empieza de cero/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/nota \(opcional/i)).toHaveValue("");
  });

  it("sin nota: POST …/apagar con cuerpo vacío y aviso de éxito", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { resultado: "actualizada", estado: ESTADO_APAGADO }));
    const props = montar();
    await userEvent.click(apagar());
    expect(vi.mocked(apiFetch).mock.calls[0][0]).toBe("/api/terminales/configuracion/activacion-por-huella/apagar");
    expect(JSON.parse(vi.mocked(apiFetch).mock.calls[0][1]!.body as string)).toEqual({});
    expect(props.onActualizado).toHaveBeenCalledWith(ESTADO_APAGADO, expect.objectContaining({ tipo: "exito", texto: expect.stringContaining("apagada") }));
  });

  it("con nota: la manda saneada", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { resultado: "actualizada", estado: ESTADO_APAGADO }));
    montar();
    await userEvent.type(screen.getByLabelText(/nota \(opcional/i), "  terminó   el alta  ");
    await userEvent.click(apagar());
    expect(JSON.parse(vi.mocked(apiFetch).mock.calls[0][1]!.body as string)).toEqual({ nota: "terminó el alta" });
  });

  it("sin_cambio: avisa que ya estaba apagado", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { resultado: "sin_cambio", estado: ESTADO_APAGADO }));
    const props = montar();
    await userEvent.click(apagar());
    expect(props.onActualizado).toHaveBeenCalledWith(ESTADO_APAGADO, expect.objectContaining({ tipo: "aviso", texto: expect.stringContaining("Ya estaba apagado") }));
  });

  it("mientras envía bloquea el modal y evita el doble envío", async () => {
    vi.mocked(apiFetch).mockImplementation(() => new Promise<Response>(() => {}));
    montar();
    await userEvent.click(apagar());
    expect(screen.getByRole("button", { name: /apagando/i })).toBeDisabled();
    expect(screen.getByRole("button", { name: /volver/i })).toBeDisabled();
    expect(apiFetch).toHaveBeenCalledTimes(1);
  });

  it("operación concurrente: mensaje fijo y botón Reintentar que reenvía", async () => {
    vi.mocked(apiFetch).mockReturnValueOnce(respuesta(503, { codigo: "reintentar", detail: "x" }));
    const props = montar();
    await userEvent.click(apagar());
    expect(await screen.findByRole("alert")).toHaveTextContent(/operación concurrente; vuelve a intentarlo/i);
    vi.mocked(apiFetch).mockReturnValueOnce(respuesta(200, { resultado: "actualizada", estado: ESTADO_APAGADO }));
    await userEvent.click(screen.getByRole("button", { name: /reintentar/i }));
    expect(props.onActualizado).toHaveBeenCalledTimes(1);
  });

  it("403: texto fijo de permiso, nunca el detail crudo", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(403, { detail: "interno <b>x</b>" }));
    montar();
    await userEvent.click(apagar());
    const alerta = await screen.findByRole("alert");
    expect(alerta).toHaveTextContent("No tienes permiso para cambiar el interruptor de la activación por huella.");
    expect(alerta).not.toHaveTextContent(/interno/);
  });

  it("respuesta con forma inesperada: error, no éxito", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { resultado: "actualizada" }));
    const props = montar();
    await userEvent.click(apagar());
    expect(await screen.findByRole("alert")).toBeInTheDocument();
    expect(props.onActualizado).not.toHaveBeenCalled();
  });

  it("Volver y Escape cierran", async () => {
    const props = montar();
    await userEvent.click(screen.getByRole("button", { name: /volver/i }));
    fireEvent(screen.getByRole("dialog"), new Event("cancel", { cancelable: true }));
    expect(props.onCerrar).toHaveBeenCalledTimes(2);
  });
});
