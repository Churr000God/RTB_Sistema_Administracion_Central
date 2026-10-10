import { fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { ESTADO_APAGADO, ESTADO_ENCENDIDO, estadoApi } from "../testing/interruptorHuella";
import { CambiarInterruptorHuellaModal } from "./CambiarInterruptorHuellaModal";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));

const NOTA = "Alta supervisada del turno de reparto, con RH presente.";

function respuesta(status: number, cuerpo: unknown = {}) {
  return Promise.resolve(new Response(JSON.stringify(cuerpo), { status }));
}

function cuerpoPost(): Record<string, unknown> {
  return JSON.parse(vi.mocked(apiFetch).mock.calls.at(-1)![1]!.body as string);
}

function montar(modo: "encender" | "renovar", estado: Record<string, unknown> = modo === "renovar" ? ESTADO_ENCENDIDO : ESTADO_APAGADO) {
  const props = { onActualizado: vi.fn(), onRecargar: vi.fn(), onCerrar: vi.fn() };
  render(<CambiarInterruptorHuellaModal modo={modo} estado={estado as never} {...props} />);
  return props;
}

const boton = (nombre: RegExp) => screen.getByRole("button", { name: nombre });

describe("CambiarInterruptorHuellaModal", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date(2026, 9, 10, 11, 20));
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("encender: advierte que se activarán altas por inferencia y no pre-llena la nota", () => {
    montar("encender");
    expect(screen.getByRole("dialog", { name: /encender la activación por huella/i })).toBeInTheDocument();
    expect(screen.getByText(/se activarán altas por inferencia/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/motivo/i)).toHaveValue("");
    expect(screen.getByText(/no escribas datos personales de nadie/i)).toBeInTheDocument();
  });

  it("la fecha sale del rango del servidor y la ayuda dice que vence a las 23:59 hora de México", () => {
    montar("encender");
    const fecha = screen.getByLabelText(/activo hasta/i);
    expect(fecha).toHaveAttribute("min", "2026-10-10");
    expect(fecha).toHaveAttribute("max", "2026-11-09");
    expect(fecha).toHaveValue("2026-10-24");
    expect(screen.getByText(/vence el 24 oct 2026 a las 23:59 \(hora de méxico\)/i)).toBeInTheDocument();
  });

  it("los atajos 7/14/30 rellenan la fecha dentro del rango", async () => {
    montar("encender");
    await userEvent.click(boton(/^7 días$/));
    expect(screen.getByLabelText(/activo hasta/i)).toHaveValue("2026-10-17");
    await userEvent.click(boton(/^30 días$/));
    expect(screen.getByLabelText(/activo hasta/i)).toHaveValue("2026-11-09");
    await userEvent.click(boton(/^14 días$/));
    expect(screen.getByLabelText(/activo hasta/i)).toHaveValue("2026-10-24");
  });

  it("contador de la nota", async () => {
    montar("encender");
    expect(screen.getByText("0 / 500 · mínimo 10")).toBeInTheDocument();
    await userEvent.type(screen.getByLabelText(/motivo/i), "hola");
    expect(screen.getByText("4 / 500 · mínimo 10")).toBeInTheDocument();
  });

  it("nota corta: error de campo y no llama al servidor; 10 caracteres sí", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { resultado: "actualizada", estado: ESTADO_ENCENDIDO }));
    const props = montar("encender");
    fireEvent.change(screen.getByLabelText(/motivo/i), { target: { value: "123456789" } });
    await userEvent.click(boton(/encender la activación/i));
    expect(screen.getByText(/la nota debe tener entre 10 y 500 caracteres/i)).toBeInTheDocument();
    expect(apiFetch).not.toHaveBeenCalled();
    fireEvent.change(screen.getByLabelText(/motivo/i), { target: { value: "1234567890" } });
    await userEvent.click(boton(/encender la activación/i));
    expect(props.onActualizado).toHaveBeenCalledTimes(1);
  });

  it("fecha fuera de rango (saltando el max del input): no llama al servidor", async () => {
    montar("encender");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    fireEvent.change(screen.getByLabelText(/activo hasta/i), { target: { value: "2026-12-31" } });
    expect(screen.getByText(/elige una fecha entre el 10 oct 2026 y el 09 nov 2026/i)).toBeInTheDocument();
    await userEvent.click(boton(/encender la activación/i));
    expect(apiFetch).not.toHaveBeenCalled();
  });

  it("encender: POST con nota saneada y hasta_fecha, sin hasta_base; avisa el éxito", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { resultado: "actualizada", estado: ESTADO_ENCENDIDO }));
    const props = montar("encender");
    await userEvent.type(screen.getByLabelText(/motivo/i), `   ${NOTA}   `);
    await userEvent.click(boton(/^7 días$/));
    await userEvent.click(boton(/encender la activación/i));
    expect(vi.mocked(apiFetch).mock.calls[0][0]).toBe("/api/terminales/configuracion/activacion-por-huella/encender");
    expect(vi.mocked(apiFetch).mock.calls[0][1]?.method).toBe("POST");
    expect(cuerpoPost()).toEqual({ nota: NOTA, hasta_fecha: "2026-10-17" });
    expect(props.onActualizado).toHaveBeenCalledWith(
      ESTADO_ENCENDIDO,
      expect.objectContaining({ tipo: "exito", texto: expect.stringContaining("encendida hasta el 24 oct 2026") }),
    );
  });

  it("renovar: nota vacía, manda hasta_base = el hasta que la pantalla tenía", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { resultado: "actualizada", estado: estadoApi({ hasta: "2026-10-31T05:59:59Z", hasta_fecha: "2026-10-30" }) }));
    const props = montar("renovar");
    expect(screen.getByRole("dialog", { name: /renovar la activación por huella/i })).toBeInTheDocument();
    expect(screen.getByLabelText(/motivo/i)).toHaveValue("");
    expect(screen.getByText(/hoy vence el 24 oct 2026/i)).toBeInTheDocument();
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/renovar la activación/i));
    expect(vi.mocked(apiFetch).mock.calls[0][0]).toBe("/api/terminales/configuracion/activacion-por-huella/renovar");
    expect(cuerpoPost()).toEqual({ nota: NOTA, hasta_fecha: "2026-10-24", hasta_base: "2026-10-25T05:59:59Z" });
    expect(props.onActualizado).toHaveBeenCalledWith(expect.anything(), expect.objectContaining({ texto: expect.stringContaining("30 oct 2026") }));
  });

  it("mientras envía bloquea el modal y evita el doble envío", async () => {
    vi.mocked(apiFetch).mockImplementation(() => new Promise<Response>(() => {}));
    montar("encender");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/encender la activación/i));
    expect(boton(/encendiendo/i)).toBeDisabled();
    expect(boton(/volver/i)).toBeDisabled();
    expect(screen.getByLabelText(/motivo/i)).toBeDisabled();
    expect(apiFetch).toHaveBeenCalledTimes(1);
  });

  it.each([
    [409, { codigo: "terminal_no_activa", detail: "x" }, "No hay ninguna terminal activa; no se puede encender."],
    [422, { codigo: "nota_repetida", detail: "x" }, "Escribe un motivo nuevo para la renovación."],
    [422, { codigo: "hasta_invalido", detail: "x" }, "El vencimiento debe ser una fecha futura de a lo más 30 días."],
    [422, { codigo: "nota_requerida", detail: "x" }, "La nota debe tener entre 10 y 500 caracteres."],
    [403, { detail: "interno" }, "No tienes permiso para cambiar el interruptor de la activación por huella."],
    [500, { detail: "stack interno" }, "No se pudo completar. Inténtalo de nuevo."],
  ])("error %i %j: texto fijo y conserva lo escrito", async (status, cuerpo, esperado) => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(status, cuerpo));
    montar("encender");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/encender la activación/i));
    const alerta = await screen.findByRole("alert");
    expect(alerta).toHaveTextContent(esperado);
    expect(alerta).not.toHaveTextContent(/interno|"x"/);
    expect(screen.getByLabelText(/motivo/i)).toHaveValue(NOTA);
    expect(boton(/encender la activación/i)).toBeEnabled();
  });

  it("sin consentimiento definitivo: enlace a Texto de consentimiento", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(409, { codigo: "sin_consentimiento_vigente", detail: "x" }));
    montar("encender");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/encender la activación/i));
    expect(await screen.findByRole("link", { name: /texto de consentimiento/i })).toHaveAttribute("href", "/tiempo/terminales/configuracion");
  });

  it("operación concurrente (503 reintentar): el botón pasa a «Reintentar» y reenvía lo mismo", async () => {
    vi.mocked(apiFetch).mockReturnValueOnce(respuesta(503, { codigo: "reintentar", detail: "x" }));
    const props = montar("encender");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/encender la activación/i));
    expect(await screen.findByRole("alert")).toHaveTextContent(/operación concurrente; vuelve a intentarlo/i);
    vi.mocked(apiFetch).mockReturnValueOnce(respuesta(200, { resultado: "actualizada", estado: ESTADO_ENCENDIDO }));
    await userEvent.click(boton(/reintentar/i));
    expect(apiFetch).toHaveBeenCalledTimes(2);
    expect(props.onActualizado).toHaveBeenCalledTimes(1);
  });

  it("estado_desactualizado al renovar: entrega el estado devuelto y avisa; no muestra error en el modal", async () => {
    const actual = estadoApi({ hasta: "2026-10-29T05:59:59Z", hasta_fecha: "2026-10-28" });
    vi.mocked(apiFetch).mockReturnValue(respuesta(409, { codigo: "estado_desactualizado", detail: "x", estado: actual }));
    const props = montar("renovar");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/renovar la activación/i));
    expect(props.onActualizado).toHaveBeenCalledWith(actual, expect.objectContaining({ tipo: "aviso", texto: expect.stringContaining("el estado cambió") }));
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("ya_esta_encendido al encender: refresca con el estado devuelto", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(409, { codigo: "ya_esta_encendido", detail: "x", estado: ESTADO_ENCENDIDO }));
    const props = montar("encender");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/encender la activación/i));
    expect(props.onActualizado).toHaveBeenCalledWith(ESTADO_ENCENDIDO, expect.objectContaining({ tipo: "aviso", texto: expect.stringContaining("Ya estaba encendido") }));
  });

  it("un 409 de refresco sin estado completo no refresca: cae al error genérico", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(409, { codigo: "estado_desactualizado", estado: { activo: true } }));
    const props = montar("renovar");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/renovar la activación/i));
    expect(await screen.findByRole("alert")).toBeInTheDocument();
    expect(props.onActualizado).not.toHaveBeenCalled();
  });

  it("no_esta_encendido al renovar: ofrece Actualizar estado", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(409, { codigo: "no_esta_encendido", detail: "x" }));
    const props = montar("renovar");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/renovar la activación/i));
    expect(await screen.findByRole("alert")).toHaveTextContent(/ya no está encendido/i);
    await userEvent.click(boton(/actualizar estado/i));
    expect(props.onRecargar).toHaveBeenCalled();
  });

  it("respuesta 200 con forma inesperada: error, no éxito", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { resultado: "actualizada" }));
    const props = montar("encender");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/encender la activación/i));
    expect(await screen.findByRole("alert")).toBeInTheDocument();
    expect(props.onActualizado).not.toHaveBeenCalled();
  });

  it("Volver y Escape cierran", async () => {
    const props = montar("encender");
    await userEvent.click(boton(/volver/i));
    expect(props.onCerrar).toHaveBeenCalledTimes(1);
    fireEvent(screen.getByRole("dialog"), new Event("cancel", { cancelable: true }));
    expect(props.onCerrar).toHaveBeenCalledTimes(2);
  });
});

describe("CambiarInterruptorHuellaModal · éxito sin fecha (security F4)", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("si el estado devuelto no trae hasta_fecha, el aviso usa «—» y nunca imprime «null»", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { resultado: "actualizada", estado: estadoApi({ hasta: null, hasta_fecha: null }) }));
    const props = montar("encender");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/encender la activación/i));
    const aviso = props.onActualizado.mock.calls[0][1] as { texto: string };
    expect(aviso.texto).toContain("hasta el —.");
    expect(aviso.texto).not.toMatch(/null/);
  });

  it("lo mismo al renovar", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { resultado: "actualizada", estado: estadoApi({ hasta: null, hasta_fecha: null }) }));
    const props = montar("renovar");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/renovar la activación/i));
    const aviso = props.onActualizado.mock.calls[0][1] as { texto: string };
    expect(aviso.texto).toContain("hasta el —.");
    expect(aviso.texto).not.toMatch(/null/);
  });
});

describe("CambiarInterruptorHuellaModal · huecos de mutación", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date(2026, 9, 10, 11, 20));
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  const VENCIDO = estadoApi({ activo: false, estado: "vencido", vencido: true, motivo: "vencido", hasta: "2026-10-06T05:59:59Z", hasta_fecha: "2026-10-05" });

  it("encender NUNCA manda hasta_base, ni siquiera «Encender de nuevo» desde vencido (que sí trae un hasta)", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { resultado: "actualizada", estado: ESTADO_ENCENDIDO }));
    montar("encender", VENCIDO);
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/encender la activación/i));
    const cuerpo = cuerpoPost();
    expect(Object.keys(cuerpo).sort()).toEqual(["hasta_fecha", "nota"]);
    expect(cuerpo).not.toHaveProperty("hasta_base");
  });

  it("renovar sin hasta en el estado no inventa hasta_base", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { resultado: "actualizada", estado: ESTADO_ENCENDIDO }));
    montar("renovar", estadoApi({ hasta: null }));
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/renovar la activación/i));
    expect(cuerpoPost()).not.toHaveProperty("hasta_base");
  });

  it("200 con forma inválida: error genérico, el botón principal sigue habilitado y nada se rompe", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { resultado: "actualizada", estado: { activo: true } }));
    const props = montar("encender");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/encender la activación/i));
    expect(await screen.findByRole("alert")).toHaveTextContent("No se pudo completar. Inténtalo de nuevo.");
    expect(boton(/encender la activación/i)).toBeEnabled();
    expect(props.onActualizado).not.toHaveBeenCalled();
    expect(props.onCerrar).not.toHaveBeenCalled();
  });

  it("no_esta_encendido: se oculta el botón principal y Actualizar estado pide recargar", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(409, { codigo: "no_esta_encendido", detail: "x" }));
    const props = montar("renovar");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/renovar la activación/i));
    await screen.findByRole("alert");
    expect(screen.queryByRole("button", { name: /renovar la activación|reintentar/i })).not.toBeInTheDocument();
    await userEvent.click(boton(/actualizar estado/i));
    expect(props.onRecargar).toHaveBeenCalledTimes(1);
  });

  it("terminal_no_activa: enlace «Ver Terminales →»; otros errores no lo muestran", async () => {
    vi.mocked(apiFetch).mockReturnValueOnce(respuesta(409, { codigo: "terminal_no_activa", detail: "x" }));
    montar("encender");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/encender la activación/i));
    expect(await screen.findByRole("link", { name: /ver terminales/i })).toHaveAttribute("href", "/tiempo/terminales");
    expect(screen.queryByRole("link", { name: /texto de consentimiento/i })).not.toBeInTheDocument();
  });

  it("un error genérico no muestra ningún enlace", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(500, {}));
    montar("encender");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/encender la activación/i));
    await screen.findByRole("alert");
    expect(screen.queryByRole("link")).not.toBeInTheDocument();
  });

  it("renovar: texto de éxito exacto y título «No se renovó» en el error; encender usa «No se encendió»", async () => {
    vi.mocked(apiFetch).mockReturnValueOnce(respuesta(422, { codigo: "nota_repetida", detail: "x" }));
    const props = montar("renovar");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/renovar la activación/i));
    const alerta = await screen.findByRole("alert");
    expect(alerta).toHaveTextContent("No se renovó");
    expect(alerta).not.toHaveTextContent("No se encendió");
    vi.mocked(apiFetch).mockReturnValueOnce(respuesta(200, { resultado: "actualizada", estado: estadoApi({ hasta_fecha: "2026-10-30" }) }));
    await userEvent.click(boton(/renovar la activación/i));
    expect(props.onActualizado.mock.calls[0][1]).toEqual({
      tipo: "exito",
      texto: "Vencimiento renovado: ahora hasta el 30 oct 2026. Tu nota quedó en el historial.",
    });
  });

  it("encender: texto de éxito exacto y título «No se encendió» en el error", async () => {
    vi.mocked(apiFetch).mockReturnValueOnce(respuesta(403, {}));
    const props = montar("encender");
    await userEvent.type(screen.getByLabelText(/motivo/i), NOTA);
    await userEvent.click(boton(/encender la activación/i));
    expect(await screen.findByRole("alert")).toHaveTextContent("No se encendió");
    vi.mocked(apiFetch).mockReturnValueOnce(respuesta(200, { resultado: "actualizada", estado: ESTADO_ENCENDIDO }));
    await userEvent.click(boton(/encender la activación/i));
    expect(props.onActualizado.mock.calls[0][1]).toEqual({
      tipo: "exito",
      texto: "Activación por huella encendida hasta el 24 oct 2026. Apágala cuando termine el alta supervisada.",
    });
  });
});
