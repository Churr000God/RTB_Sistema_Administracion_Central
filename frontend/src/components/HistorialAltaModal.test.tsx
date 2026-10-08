import { fireEvent, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { HistorialAltaModal } from "./HistorialAltaModal";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));

const ALTA = { id: 77, persona_nombre: "Sofía Vega", employee_no: 1027 };

const MOVIMIENTOS = [
  { id: 5, tipo_movimiento: "reconsentido", creado_en: "2026-10-08T18:30:00Z", origen: "web", registrado_por_nombre: "María López", detalle: "reconsentimiento recabado: versión 4", huellas_capturadas: null, consentimiento: { id: 4, version: 4, cambio_material: true } },
  { id: 4, tipo_movimiento: "baja_solicitada", creado_en: "2026-10-07T15:12:00Z", origen: "web", registrado_por_nombre: "Responsable de RH", detalle: "baja automática: la persona pasó a suspension", huellas_capturadas: null, consentimiento: null },
  { id: 3, tipo_movimiento: "huella_capturada", creado_en: "2026-09-29T16:05:00Z", origen: "terminal", registrado_por_nombre: null, detalle: null, huellas_capturadas: 2, consentimiento: null },
  { id: 2, tipo_movimiento: "error", creado_en: "2026-09-28T15:20:00Z", origen: "terminal", registrado_por_nombre: null, detalle: "usuario_ya_existe: <b>reintentando</b>", huellas_capturadas: null, consentimiento: null },
  { id: 1, tipo_movimiento: "asignado", creado_en: "2026-09-28T15:00:00Z", origen: "web", registrado_por_nombre: "Carlos Ruiz", detalle: "consentimiento y aviso de privacidad recabados: versión 2", huellas_capturadas: null, consentimiento: { id: 2, version: 2 } },
];

function mockApi(respuesta: () => Response) {
  vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(respuesta()));
}

describe("HistorialAltaModal", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("pide los movimientos del alta y los lista con tipo, quién y detalle como texto plano", async () => {
    mockApi(() => new Response(JSON.stringify(MOVIMIENTOS)));
    const { baseElement } = render(<HistorialAltaModal terminalId={1} alta={ALTA} onCerrar={vi.fn()} />);
    expect(await screen.findByText("Reconsentimiento registrado")).toBeInTheDocument();
    expect(vi.mocked(apiFetch).mock.calls[0][0]).toBe("/api/terminales/1/usuarios/77/movimientos");
    expect(screen.getByText("Baja solicitada")).toBeInTheDocument();
    expect(screen.getByText(/María López/)).toBeInTheDocument();
    expect(screen.getByText(/baja automática: la persona pasó a suspension/)).toBeInTheDocument();
    // el detalle del servidor jamás se interpreta como HTML
    expect(screen.getByText(/usuario_ya_existe: <b>reintentando<\/b>/)).toBeInTheDocument();
    expect(baseElement.querySelector("b")).toBeNull();
  });

  it("origen terminal sin autor se muestra como «Terminal»; huella capturada trae el conteo", async () => {
    mockApi(() => new Response(JSON.stringify(MOVIMIENTOS)));
    render(<HistorialAltaModal terminalId={1} alta={ALTA} onCerrar={vi.fn()} />);
    const item = (await screen.findByText("Huella capturada")).closest("li")!;
    expect(within(item).getByText(/Terminal/)).toBeInTheDocument();
    expect(within(item).getByText(/2 huellas registradas/i)).toBeInTheDocument();
  });

  it("muestra «Consentimiento vN» (columna, no detalle) y marca el cambio material", async () => {
    mockApi(() => new Response(JSON.stringify(MOVIMIENTOS)));
    render(<HistorialAltaModal terminalId={1} alta={ALTA} onCerrar={vi.fn()} />);
    const reconsentido = (await screen.findByText("Reconsentimiento registrado")).closest("li")!;
    expect(within(reconsentido).getByText(/Consentimiento v4/)).toBeInTheDocument();
    expect(within(reconsentido).getByText(/cambio material/i)).toBeInTheDocument();
    const asignada = screen.getByText("Asignada").closest("li")!;
    expect(within(asignada).getByText(/Consentimiento v2/)).toBeInTheDocument();
    expect(within(asignada).queryByText(/cambio material/i)).not.toBeInTheDocument();
  });

  it("el error del puente se distingue en la línea de tiempo", async () => {
    mockApi(() => new Response(JSON.stringify(MOVIMIENTOS)));
    render(<HistorialAltaModal terminalId={1} alta={ALTA} onCerrar={vi.fn()} />);
    expect((await screen.findByText("Error del puente")).closest("li")).toHaveClass("error");
  });

  it("cargando, vacío, error con Reintentar y 404", async () => {
    vi.mocked(apiFetch).mockImplementation(() => new Promise<Response>(() => {}));
    const a = render(<HistorialAltaModal terminalId={1} alta={ALTA} onCerrar={vi.fn()} />);
    expect(screen.getByText(/cargando historial/i)).toBeInTheDocument();
    a.unmount();

    mockApi(() => new Response("[]"));
    const b = render(<HistorialAltaModal terminalId={1} alta={ALTA} onCerrar={vi.fn()} />);
    expect(await screen.findByText(/todavía no tiene movimientos/i)).toBeInTheDocument();
    b.unmount();

    let falla = true;
    mockApi(() => (falla ? new Response(null, { status: 500 }) : new Response(JSON.stringify(MOVIMIENTOS))));
    const c = render(<HistorialAltaModal terminalId={1} alta={ALTA} onCerrar={vi.fn()} />);
    expect(await screen.findByText(/no se pudo cargar el historial/i)).toBeInTheDocument();
    falla = false;
    await userEvent.click(screen.getByRole("button", { name: /reintentar/i }));
    expect(await screen.findByText("Asignada")).toBeInTheDocument();
    c.unmount();

    mockApi(() => new Response(JSON.stringify({ detail: "x" }), { status: 404 }));
    render(<HistorialAltaModal terminalId={1} alta={ALTA} onCerrar={vi.fn()} />);
    expect(await screen.findByText(/esta alta ya no existe/i)).toBeInTheDocument();
  });

  it("Cerrar y Escape cierran el diálogo", async () => {
    mockApi(() => new Response("[]"));
    const onCerrar = vi.fn();
    render(<HistorialAltaModal terminalId={1} alta={ALTA} onCerrar={onCerrar} />);
    await screen.findByText(/todavía no tiene movimientos/i);
    await userEvent.click(screen.getByRole("button", { name: /cerrar/i }));
    expect(onCerrar).toHaveBeenCalledTimes(1);
    fireEvent(screen.getByRole("dialog"), new Event("cancel", { cancelable: true }));
    expect(onCerrar).toHaveBeenCalledTimes(2);
  });
});
