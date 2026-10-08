import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { DescartarMarcaTardiaModal } from "./DescartarMarcaTardiaModal";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));

const EXCEPCION = {
  id: 5,
  persona_nombre: "Luis Ramírez",
  momento_dispositivo: "2026-10-04T02:41:00Z",
  dia_de_la_marca_fecha: "2026-10-03",
  dia_de_la_marca_estado: "revisado" as const,
};

function respuesta(status: number, cuerpo: unknown) {
  return Promise.resolve(new Response(JSON.stringify(cuerpo), { status }));
}

async function escribirYEnviar(texto = "Registro accidental después de la salida.") {
  await userEvent.type(screen.getByLabelText(/motivo del descarte/i), texto);
  await userEvent.click(screen.getByRole("button", { name: /descartar definitivamente/i }));
}

describe("DescartarMarcaTardiaModal", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("abre un diálogo modal con contexto y la advertencia de irreversible y auditado", () => {
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={vi.fn()} />);
    const dialogo = screen.getByRole("dialog", { name: /descartar marca tardía/i });
    expect(dialogo).toHaveTextContent("Luis Ramírez");
    expect(dialogo).toHaveTextContent(/irreversible/i);
    expect(dialogo).toHaveTextContent(/quién/i);
    expect(dialogo).toHaveTextContent(/por qué/i);
  });

  it("no envía con motivo vacío o sólo espacios y muestra el error del campo", async () => {
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={vi.fn()} />);
    await userEvent.type(screen.getByLabelText(/motivo del descarte/i), "   ");
    await userEvent.click(screen.getByRole("button", { name: /descartar definitivamente/i }));
    expect(apiFetch).not.toHaveBeenCalled();
    expect(screen.getByText(/escribe un motivo \(entre 1 y 500 caracteres\)/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/motivo del descarte/i)).toHaveAttribute("aria-invalid", "true");
  });

  it("limita el motivo a 500 caracteres y muestra el contador", async () => {
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={vi.fn()} />);
    expect(screen.getByLabelText(/motivo del descarte/i)).toHaveAttribute("maxlength", "500");
    await userEvent.type(screen.getByLabelText(/motivo del descarte/i), "hola");
    expect(screen.getByText("4 / 500")).toBeInTheDocument();
  });

  it("POST con el motivo recortado y, si descartó, avisa éxito y refresca al cerrar", async () => {
    const onCerrar = vi.fn();
    vi.mocked(apiFetch).mockReturnValue(
      respuesta(200, { resultado: "descartada", excepcion_id: 5, dia_id: 9 }),
    );
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={onCerrar} />);

    await escribirYEnviar("  Motivo válido.  ");

    expect(await screen.findByText(/marca descartada/i)).toBeInTheDocument();
    const [ruta, init] = vi.mocked(apiFetch).mock.calls[0];
    expect(ruta).toBe("/api/excepciones/5/descartar");
    expect(init?.method).toBe("POST");
    expect(JSON.parse(init!.body as string)).toEqual({ motivo: "Motivo válido." });

    await userEvent.click(screen.getByRole("button", { name: /cerrar/i }));
    expect(onCerrar).toHaveBeenCalledWith(true);
  });

  it("ya_descartada se distingue del éxito: no hubo cambio", async () => {
    vi.mocked(apiFetch).mockReturnValue(
      respuesta(200, { resultado: "ya_descartada", excepcion_id: 5, dia_id: 9 }),
    );
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={vi.fn()} />);
    await escribirYEnviar();
    expect(await screen.findByText(/ya estaba descartada/i)).toBeInTheDocument();
    expect(screen.getByText(/no se hizo ningún cambio/i)).toBeInTheDocument();
  });

  it("mientras envía deshabilita Cancelar y evita el doble envío", async () => {
    let resolver!: (r: Response) => void;
    vi.mocked(apiFetch).mockReturnValue(new Promise<Response>((r) => (resolver = r)));
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={vi.fn()} />);
    await escribirYEnviar();

    expect(screen.getByRole("button", { name: /descartando/i })).toBeDisabled();
    expect(screen.getByRole("button", { name: /cancelar/i })).toBeDisabled();
    expect(apiFetch).toHaveBeenCalledTimes(1);

    resolver(new Response(JSON.stringify({ resultado: "descartada", excepcion_id: 5 })));
    await screen.findByText(/marca descartada/i);
  });

  it.each([
    [403, "No tienes permiso para esta acción."],
    [422, "El motivo es obligatorio."],
    [503, "Servicio no disponible; reintenta."],
    [500, "No se pudo completar. Inténtalo de nuevo."],
  ])("error %i: siempre el mensaje de respaldo, aunque el servidor mande otro detail", async (status, respaldo) => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(status, { detail: "SELECT interno: tabla tiempo.excepcion id=5" }));
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={vi.fn()} />);
    await escribirYEnviar("Texto que no debe perderse.");

    const alerta = await screen.findByRole("alert");
    expect(alerta).toHaveTextContent(respaldo);
    expect(alerta).not.toHaveTextContent(/SELECT interno/);
    expect(screen.getByLabelText(/motivo del descarte/i)).toHaveValue("Texto que no debe perderse.");
    expect(screen.queryByRole("button", { name: /actualizar lista/i })).not.toBeInTheDocument();
  });

  it.each([
    [503, "Servicio no disponible; reintenta."],
    [500, "No se pudo completar. Inténtalo de nuevo."],
  ])("error %i sin cuerpo JSON usa el respaldo", async (status, respaldo) => {
    vi.mocked(apiFetch).mockReturnValue(Promise.resolve(new Response("<html>boom</html>", { status })));
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={vi.fn()} />);
    await escribirYEnviar();
    expect(await screen.findByRole("alert")).toHaveTextContent(respaldo);
  });

  it("409: muestra el detail fijo del backend y ofrece Actualizar lista", async () => {
    const detail = "El día todavía no está revisado: revísalo en vez de descartar la marca.";
    vi.mocked(apiFetch).mockReturnValue(respuesta(409, { detail }));
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={vi.fn()} />);
    await escribirYEnviar("Texto que no debe perderse.");
    expect(await screen.findByRole("alert")).toHaveTextContent(detail);
    expect(screen.getByRole("button", { name: /actualizar lista/i })).toBeEnabled();
    expect(screen.getByLabelText(/motivo del descarte/i)).toHaveValue("Texto que no debe perderse.");
  });

  it("409 sin detail legible cae al respaldo del 409", async () => {
    vi.mocked(apiFetch).mockReturnValue(Promise.resolve(new Response("", { status: 409 })));
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={vi.fn()} />);
    await escribirYEnviar();
    expect(await screen.findByRole("alert")).toHaveTextContent(/actualiza la lista/i);
  });

  it("falla de red: mensaje genérico y se puede reintentar", async () => {
    vi.mocked(apiFetch).mockRejectedValue(new Error("red"));
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={vi.fn()} />);
    await escribirYEnviar();
    expect(await screen.findByRole("alert")).toHaveTextContent(/no se pudo completar/i);
    await waitFor(() =>
      expect(screen.getByRole("button", { name: /descartar definitivamente/i })).toBeEnabled(),
    );
  });

  it("Actualizar lista tras un 409 cierra pidiendo refresco; Cancelar cierra sin refrescar", async () => {
    const onCerrar = vi.fn();
    vi.mocked(apiFetch).mockReturnValue(respuesta(409, { detail: "La excepción ya fue descartada antes." }));
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={onCerrar} />);
    await escribirYEnviar();
    await userEvent.click(await screen.findByRole("button", { name: /actualizar lista/i }));
    expect(onCerrar).toHaveBeenCalledWith(true);

    const onCerrar2 = vi.fn();
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={onCerrar2} />);
    await userEvent.click(screen.getAllByRole("button", { name: /cancelar/i }).at(-1)!);
    expect(onCerrar2).toHaveBeenCalledWith(false);
  });

  it("abre con showModal() exactamente una vez al montar (modal real, no un diálogo suelto)", () => {
    const espia = vi.spyOn(HTMLDialogElement.prototype, "showModal");
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={vi.fn()} />);
    expect(espia).toHaveBeenCalledTimes(1);
    espia.mockRestore();
  });

  it("Escape mientras envía no cierra y el evento queda cancelado", async () => {
    vi.mocked(apiFetch).mockReturnValue(new Promise<Response>(() => {}));
    const onCerrar = vi.fn();
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={onCerrar} />);
    await escribirYEnviar();
    const evento = new Event("cancel", { cancelable: true });
    fireEvent(screen.getByRole("dialog"), evento);
    expect(onCerrar).not.toHaveBeenCalled();
    expect(evento.defaultPrevented).toBe(true);
  });

  it("Escape editando cierra sin refrescar", () => {
    const onCerrar = vi.fn();
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={onCerrar} />);
    fireEvent(screen.getByRole("dialog"), new Event("cancel", { cancelable: true }));
    expect(onCerrar).toHaveBeenCalledWith(false);
  });

  it("Escape después de descartar cierra pidiendo refresco", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { resultado: "descartada", excepcion_id: 5 }));
    const onCerrar = vi.fn();
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={onCerrar} />);
    await escribirYEnviar();
    await screen.findByRole("status");
    fireEvent(screen.getByRole("dialog"), new Event("cancel", { cancelable: true }));
    expect(onCerrar).toHaveBeenCalledWith(true);
  });

  it("cierra el <dialog> nativo antes de avisar, para que el foco vuelva al botón que lo abrió", async () => {
    const cerrar = vi.spyOn(HTMLDialogElement.prototype, "close");
    let cerroAntes = false;
    const onCerrar = vi.fn(() => {
      cerroAntes = cerrar.mock.calls.length > 0;
    });
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={onCerrar} />);
    await userEvent.click(screen.getByRole("button", { name: /cancelar/i }));
    expect(onCerrar).toHaveBeenCalledTimes(1);
    expect(cerroAntes).toBe(true);
    cerrar.mockRestore();
  });

  it("deshabilita el textarea mientras se envía", async () => {
    vi.mocked(apiFetch).mockReturnValue(new Promise<Response>(() => {}));
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={vi.fn()} />);
    await escribirYEnviar();
    expect(screen.getByLabelText(/motivo del descarte/i)).toBeDisabled();
  });

  it("descartada y ya_descartada se anuncian como status", async () => {
    vi.mocked(apiFetch).mockReturnValueOnce(respuesta(200, { resultado: "descartada", excepcion_id: 5 }));
    const { unmount } = render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={vi.fn()} />);
    await escribirYEnviar();
    expect(await screen.findByRole("status")).toHaveTextContent(/marca descartada/i);
    unmount();

    vi.mocked(apiFetch).mockReturnValueOnce(respuesta(200, { resultado: "ya_descartada", excepcion_id: 5 }));
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={vi.fn()} />);
    await escribirYEnviar();
    expect(await screen.findByRole("status")).toHaveTextContent(/ya estaba descartada/i);
  });

  it("501 caracteres (saltando maxLength) no se envían y marcan el campo; 500 exactos sí", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { resultado: "descartada", excepcion_id: 5 }));
    render(<DescartarMarcaTardiaModal excepcion={EXCEPCION} onCerrar={vi.fn()} />);
    const campo = screen.getByLabelText(/motivo del descarte/i);

    fireEvent.change(campo, { target: { value: "a".repeat(501) } });
    await userEvent.click(screen.getByRole("button", { name: /descartar definitivamente/i }));
    expect(apiFetch).not.toHaveBeenCalled();
    expect(screen.getByText(/escribe un motivo \(entre 1 y 500 caracteres\)/i)).toBeInTheDocument();

    fireEvent.change(campo, { target: { value: "a".repeat(500) } });
    await userEvent.click(screen.getByRole("button", { name: /descartar definitivamente/i }));
    await waitFor(() => expect(apiFetch).toHaveBeenCalledTimes(1));
  });
});
