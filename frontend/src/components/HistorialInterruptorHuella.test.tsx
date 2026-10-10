import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { HistorialInterruptorHuella } from "./HistorialInterruptorHuella";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));

const ITEMS = [
  { id: 3, creado_en: "2026-10-10T15:30:00Z", clave: "terminal_inferir_huella_activa", operacion: "UPDATE", valor_anterior: "0", valor_nuevo: "1", nota: "Alta supervisada <b>12</b> personas.", autor_nombre: "Carlos Ruiz", via_funcion: true },
  { id: 2, creado_en: "2026-10-07T22:14:00Z", clave: "terminal_inferir_huella_activa", operacion: "UPDATE", valor_anterior: "0", valor_nuevo: "1", nota: null, autor_nombre: null, via_funcion: false },
  { id: 1, creado_en: "2026-10-06T10:00:00Z", clave: "otra_cosa", operacion: "UPDATE", valor_anterior: "x", valor_nuevo: "y", nota: null, autor_nombre: "Ana", via_funcion: true },
];

function respuesta(status: number, cuerpo: unknown) {
  return Promise.resolve(new Response(JSON.stringify(cuerpo), { status }));
}

describe("HistorialInterruptorHuella", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("pide el historial con límite 50 y lo lista: cambio, nota como texto plano, autor y origen", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { items: ITEMS }));
    const { baseElement } = render(<HistorialInterruptorHuella puedeVer version={0} />);
    expect(await screen.findByText("Alta supervisada <b>12</b> personas.")).toBeInTheDocument();
    expect(baseElement.querySelector("b")).toBeNull();
    expect(vi.mocked(apiFetch).mock.calls[0][0]).toBe("/api/terminales/configuracion/activacion-por-huella/historial?limite=50");
    const filas = screen.getAllByRole("row").slice(1);
    expect(within(filas[0]).getByText("Interruptor: Apagado → Encendido")).toBeInTheDocument();
    expect(within(filas[0]).getByText("Carlos Ruiz")).toBeInTheDocument();
    expect(within(filas[0]).getByText("Desde la pantalla")).toBeInTheDocument();
    expect(within(filas[2]).getByText("Otro ajuste")).toBeInTheDocument();
  });

  it("un cambio fuera de la función se marca en rojo y sin autor", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { items: ITEMS }));
    render(<HistorialInterruptorHuella puedeVer version={0} />);
    await screen.findByText("Carlos Ruiz");
    const fila = screen.getAllByRole("row")[2];
    expect(within(fila).getByText("Fuera de la función")).toBeInTheDocument();
    expect(within(fila).getByText("Sin autor")).toBeInTheDocument();
  });

  it("vacío", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(200, { items: [] }));
    render(<HistorialInterruptorHuella puedeVer version={0} />);
    expect(await screen.findByText(/todavía no hay cambios registrados/i)).toBeInTheDocument();
  });

  it("sin permiso de detalle no pide nada y explica qué permiso hace falta", () => {
    render(<HistorialInterruptorHuella puedeVer={false} version={0} />);
    expect(screen.getByText(/el historial no está disponible con tu permiso/i)).toBeInTheDocument();
    expect(screen.getByText("terminal_usuario_edicion")).toBeInTheDocument();
    expect(apiFetch).not.toHaveBeenCalled();
  });

  it("403 del servidor: el mismo aviso de permiso, no un error", async () => {
    vi.mocked(apiFetch).mockReturnValue(respuesta(403, { detail: "No tienes permiso para esta acción." }));
    render(<HistorialInterruptorHuella puedeVer version={0} />);
    expect(await screen.findByText(/el historial no está disponible con tu permiso/i)).toBeInTheDocument();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("error 500: tarjeta propia con Reintentar que vuelve a pedir", async () => {
    vi.mocked(apiFetch).mockReturnValueOnce(respuesta(500, {}));
    render(<HistorialInterruptorHuella puedeVer version={0} />);
    expect(await screen.findByText(/no se pudo cargar el historial/i)).toBeInTheDocument();
    vi.mocked(apiFetch).mockReturnValueOnce(respuesta(200, { items: ITEMS }));
    await userEvent.click(screen.getByRole("button", { name: /reintentar/i }));
    expect(await screen.findByText("Carlos Ruiz")).toBeInTheDocument();
  });

  it("forma inesperada es error, y al cambiar `version` vuelve a pedir", async () => {
    vi.mocked(apiFetch).mockReturnValueOnce(respuesta(200, { sin: "items" }));
    const { rerender } = render(<HistorialInterruptorHuella puedeVer version={0} />);
    expect(await screen.findByText(/no se pudo cargar el historial/i)).toBeInTheDocument();
    vi.mocked(apiFetch).mockReturnValueOnce(respuesta(200, { items: ITEMS }));
    rerender(<HistorialInterruptorHuella puedeVer version={1} />);
    expect(await screen.findByText("Carlos Ruiz")).toBeInTheDocument();
    expect(apiFetch).toHaveBeenCalledTimes(2);
  });
});

describe("HistorialInterruptorHuella · renovaciones y cambios fuera de la función", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("UPDATE_VIGENCIA se rotula como cambio de vigencia y no como «Encendido → Encendido»", async () => {
    vi.mocked(apiFetch).mockReturnValue(
      respuesta(200, {
        items: [
          { id: 5, creado_en: "2026-10-11T15:00:00Z", clave: "terminal_inferir_huella_activa", operacion: "UPDATE_VIGENCIA", valor_anterior: "1", valor_nuevo: "1", nota: "Se extiende una semana.", autor_nombre: "Carlos Ruiz", via_funcion: true },
        ],
      }),
    );
    render(<HistorialInterruptorHuella puedeVer version={0} />);
    expect(await screen.findByText("Cambio de vigencia (sin cambio de valor)")).toBeInTheDocument();
    expect(screen.queryByText(/encendido → encendido/i)).not.toBeInTheDocument();
  });

  it("un renovar hecho fuera de la función conserva la marca roja", async () => {
    vi.mocked(apiFetch).mockReturnValue(
      respuesta(200, {
        items: [
          { id: 6, creado_en: "2026-10-11T15:00:00Z", clave: "terminal_inferir_huella_activa", operacion: "UPDATE_VIGENCIA", valor_anterior: "1", valor_nuevo: "1", nota: null, autor_nombre: null, via_funcion: false },
        ],
      }),
    );
    render(<HistorialInterruptorHuella puedeVer version={0} />);
    const fila = (await screen.findByText("Cambio de vigencia (sin cambio de valor)")).closest("tr")!;
    expect(within(fila).getByText("Fuera de la función")).toBeInTheDocument();
  });
});

describe("HistorialInterruptorHuella · huecos de mutación", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("nota null => «—» (no vacío ni «null»)", async () => {
    vi.mocked(apiFetch).mockReturnValue(
      respuesta(200, { items: [{ id: 1, creado_en: "2026-10-10T15:30:00Z", clave: "terminal_inferir_huella_activa", operacion: "UPDATE", valor_anterior: "1", valor_nuevo: "0", nota: null, autor_nombre: "Carlos Ruiz", via_funcion: true }] }),
    );
    render(<HistorialInterruptorHuella puedeVer version={0} />);
    const fila = (await screen.findByText("Carlos Ruiz")).closest("tr")!;
    const celdas = within(fila).getAllByRole("cell");
    expect(celdas[2]).toHaveTextContent(/^—$/);
    expect(fila).not.toHaveTextContent(/null/);
  });

  it("con puedeVer=false jamás pide el historial aunque cambie la versión", () => {
    const { rerender } = render(<HistorialInterruptorHuella puedeVer={false} version={0} />);
    rerender(<HistorialInterruptorHuella puedeVer={false} version={3} />);
    expect(apiFetch).not.toHaveBeenCalled();
  });
});
