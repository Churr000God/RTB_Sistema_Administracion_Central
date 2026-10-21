import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { DescartarAlertaHorarioModal } from "./DescartarAlertaHorarioModal";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));

const MARCA = {
  excepcionHorarioId: 77,
  persona_nombre: "Luis Ramírez",
  momento_efectivo: "2026-10-04T02:41:00Z",
};

function respuesta(status: number, cuerpo: unknown) {
  return Promise.resolve(new Response(JSON.stringify(cuerpo), { status }));
}

const MOTIVO_VALIDO = "Salió más tarde por una junta autorizada.";

async function escribir(texto = MOTIVO_VALIDO) {
  await userEvent.type(screen.getByLabelText(/motivo del descarte/i), texto);
}

const botonDescartar = () => screen.getByRole("button", { name: /^descartar alerta$/i });

describe("DescartarAlertaHorarioModal", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("explica que la marca ya está contada, la nota de datos sensibles y que no se deshace", () => {
    render(<DescartarAlertaHorarioModal marca={MARCA} onCerrar={vi.fn()} />);
    const dialogo = screen.getByRole("dialog", { name: /descartar alerta de horario/i });
    expect(dialogo).toHaveTextContent("Luis Ramírez");
    expect(dialogo).toHaveTextContent(/ya está contada en el día/i);
    expect(dialogo).toHaveTextContent(/solo cierra la alerta/i);
    expect(dialogo).toHaveTextContent(/no escribas datos médicos ni sensibles\./i);
    expect(dialogo).toHaveTextContent(/no se puede deshacer/i);
    expect(dialogo).toHaveTextContent(/bitácora/i);
  });

  it("contador y tope de 500 caracteres", async () => {
    render(<DescartarAlertaHorarioModal marca={MARCA} onCerrar={vi.fn()} />);
    expect(screen.getByLabelText(/motivo del descarte/i)).toHaveAttribute("maxlength", "500");
    await escribir("hola");
    expect(screen.getByText("4 / 500")).toBeInTheDocument();
  });

  it("con menos de 10 caracteres (recortado) no envía y marca el campo", async () => {
    render(<DescartarAlertaHorarioModal marca={MARCA} onCerrar={vi.fn()} />);
    await escribir("   123456789   "); // 9 útiles
    await userEvent.click(botonDescartar());

    expect(apiFetch).not.toHaveBeenCalled();
    expect(screen.getByText(/escribe un motivo \(entre 10 y 500 caracteres\)/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/motivo del descarte/i)).toHaveAttribute("aria-invalid", "true");
  });

  it("con exactamente 10 caracteres envía, recortado, al id de la excepción de horario", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { auditoria_id: 1, excepcion_id: 77 }));
    render(<DescartarAlertaHorarioModal marca={MARCA} onCerrar={vi.fn()} />);
    await escribir("  1234567890  ");
    await userEvent.click(botonDescartar());

    expect(await screen.findByText(/alerta descartada/i)).toBeInTheDocument();
    const [ruta, init] = vi.mocked(apiFetch).mock.calls[0];
    expect(ruta).toBe("/api/excepciones/77/descartar-alerta-horario");
    expect(init?.method).toBe("POST");
    expect(JSON.parse(init!.body as string)).toEqual({ motivo: "1234567890" });
  });

  it("tras el éxito, Cerrar pide refrescar la lista", async () => {
    const onCerrar = vi.fn();
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { auditoria_id: 1, excepcion_id: 77 }));
    render(<DescartarAlertaHorarioModal marca={MARCA} onCerrar={onCerrar} />);
    await escribir();
    await userEvent.click(botonDescartar());
    await userEvent.click(await screen.findByRole("button", { name: /^cerrar$/i }));

    expect(onCerrar).toHaveBeenCalledWith(true);
  });

  it.each([
    [403, "No puedes descartar tu propia alerta."],
    [404, "No existe la alerta indicada."],
    [422, "El motivo debe tener entre 10 y 500 caracteres."],
  ])("%i muestra el detail del backend tal cual y deja reintentar", async (status, detail) => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(status, { detail }));
    render(<DescartarAlertaHorarioModal marca={MARCA} onCerrar={vi.fn()} />);
    await escribir();
    await userEvent.click(botonDescartar());

    expect(await screen.findByText(detail)).toBeInTheDocument();
    expect(botonDescartar()).toBeEnabled();
  });

  it("409 muestra el detail y ofrece «Actualizar lista», que refresca", async () => {
    const onCerrar = vi.fn();
    vi.mocked(apiFetch).mockReturnValue(respuesta(409, { detail: "La alerta ya estaba resuelta." }));
    render(<DescartarAlertaHorarioModal marca={MARCA} onCerrar={onCerrar} />);
    await escribir();
    await userEvent.click(botonDescartar());

    expect(await screen.findByText("La alerta ya estaba resuelta.")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: /actualizar lista/i }));
    expect(onCerrar).toHaveBeenCalledWith(true);
  });

  it("sin detail usa un respaldo por status, no un texto vacío", async () => {
    vi.mocked(apiFetch).mockReturnValue(Promise.resolve(new Response("<html>", { status: 500 })));
    render(<DescartarAlertaHorarioModal marca={MARCA} onCerrar={vi.fn()} />);
    await escribir();
    await userEvent.click(botonDescartar());

    expect(await screen.findByText(/no se pudo completar\. inténtalo de nuevo\./i)).toBeInTheDocument();
  });

  it("un solo envío: dos clics seguidos con la respuesta en vuelo hacen un único POST", async () => {
    let resolver!: (r: Response) => void;
    vi.mocked(apiFetch).mockReturnValue(new Promise<Response>((res) => { resolver = res; }));
    render(<DescartarAlertaHorarioModal marca={MARCA} onCerrar={vi.fn()} />);
    await escribir();
    const boton = botonDescartar();
    await userEvent.click(boton);
    await userEvent.click(boton);
    await userEvent.click(boton);

    expect(apiFetch).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button", { name: /descartando/i })).toBeDisabled();

    resolver(new Response(JSON.stringify({ auditoria_id: 1, excepcion_id: 77 }), { status: 200 }));
    await waitFor(() => expect(screen.getByText(/alerta descartada/i)).toBeInTheDocument());
    expect(apiFetch).toHaveBeenCalledTimes(1);
  });

  it("el motivo nunca se interpreta como HTML", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { auditoria_id: 1, excepcion_id: 77 }));
    const { container } = render(<DescartarAlertaHorarioModal marca={MARCA} onCerrar={vi.fn()} />);
    await userEvent.type(screen.getByLabelText(/motivo del descarte/i), "<img src=x onerror=alert(1)> listo");
    expect(container.querySelector("img")).toBeNull();
  });
});
