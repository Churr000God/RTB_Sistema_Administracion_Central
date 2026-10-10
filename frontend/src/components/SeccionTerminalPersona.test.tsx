import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { respuestaSesion } from "../testing/sesion";
import { SeccionTerminalPersona } from "./SeccionTerminalPersona";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));

const PERSONA = {
  id: "11111111-1111-4111-8111-111111111111",
  nombre: "Ana Torres",
  puesto: "Auxiliar de almacén",
  area: "Bodega",
};

function altaDe(estado: string, extra: Record<string, unknown> = {}, terminal: Record<string, unknown> = {}) {
  return {
    alta: {
      id: 10,
      terminal_id: 1,
      employee_no: 1042,
      persona_id: PERSONA.id,
      persona_nombre: "Ana Torres",
      estado,
      huellas_capturadas: 2,
      huella_evidencia: "conteo",
      creado_en: "2026-10-01T15:00:00Z",
      actualizado_en: "2026-10-01T15:00:00Z",
      usuario_creado_en: null,
      caduca_en: null,
      error_codigo: null,
      error_detalle: null,
      consentimiento: { id: 3, version: 3, provisional: false },
      consentimiento_vigente_id: 3,
      reconsentimiento_pendiente: false,
      es_propia: false,
      reconsentimiento_elegible: false,
      reconsentimiento_razon: null,
      accion_disponible: null,
      ...extra,
    },
    terminal: { id: 1, nombre: "Entrada principal", serie: "DS-K1T-0001", estado_contacto: "en_linea", activa: true, ...terminal },
  };
}

function mockApi(opciones: { altas?: () => Response; sesion?: Record<string, unknown>; terminales?: unknown[] } = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") return Promise.resolve(respuestaSesion(opciones.sesion));
    if (path === `/api/personas/${PERSONA.id}/terminales`) return Promise.resolve(opciones.altas?.() ?? new Response("[]"));
    if (path === "/api/terminales") {
      return Promise.resolve(new Response(JSON.stringify(opciones.terminales ?? [{ id: 1, nombre: "Entrada principal", activa: true }, { id: 2, nombre: "Bodega", activa: true }, { id: 3, nombre: "Vieja", activa: false }])));
    }
    if (path === "/api/terminales/configuracion/consentimiento")
      return Promise.resolve(new Response(JSON.stringify({ vigente: { id: 3, version: 3, texto: "Texto v3", provisional: false, cambio_material: false, vigente_desde: "2026-10-02T00:00:00Z" }, historial: [] })));
    if (path === "/api/terminales/2/usuarios" && init?.method === "POST") return Promise.resolve(new Response(JSON.stringify({ id: 5, employee_no: 1100 }), { status: 201 }));
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

const renderSeccion = () => render(<SeccionTerminalPersona persona={{ persona_id: PERSONA.id, nombre: PERSONA.nombre, puesto: PERSONA.puesto, area: PERSONA.area }} />);

describe("SeccionTerminalPersona", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("sin alta: dice que marca por captura manual y ofrece Asignar a la terminal con edición", async () => {
    mockApi();
    renderSeccion();
    expect(await screen.findByText(/no está asignada a ninguna terminal/i)).toBeInTheDocument();
    expect(screen.getByText(/captura manual/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /asignar a la terminal/i })).toBeInTheDocument();
  });

  it("sin permiso de edición explica el permiso y no ofrece asignar", async () => {
    mockApi({ sesion: { puede_editar_terminales: false } });
    renderSeccion();
    expect(await screen.findByText(/no está asignada a ninguna terminal/i)).toBeInTheDocument();
    expect(screen.getByText(/terminal_usuario_edicion/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /asignar a la terminal/i })).not.toBeInTheDocument();
  });

  it("sin puede_ver_terminales la sección no aparece ni pide nada", async () => {
    mockApi({ sesion: { puede_ver_terminales: false } });
    const { container } = renderSeccion();
    await waitFor(() => expect(vi.mocked(apiFetch)).toHaveBeenCalledWith("/api/sesion"));
    expect(container).toBeEmptyDOMElement();
    expect(vi.mocked(apiFetch).mock.calls.some(([p]) => String(p).includes("/terminales") && String(p).includes("/api/personas"))).toBe(false);
  });

  it("activa: estado, terminal, nº, huellas y enlace a Usuarios de la terminal", async () => {
    mockApi({ altas: () => new Response(JSON.stringify([altaDe("activo")])) });
    renderSeccion();
    expect(await screen.findByText("Activo")).toBeInTheDocument();
    expect(screen.getByText(/Entrada principal/)).toBeInTheDocument();
    expect(screen.getByText(/nº 1042/)).toBeInTheDocument();
    expect(screen.getByText(/2 huellas/)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /ver en usuarios de la terminal/i })).toHaveAttribute("href", "/tiempo/terminales/1/usuarios");
  });

  it("esperando huella: texto claro y cuenta regresiva", async () => {
    mockApi({ altas: () => new Response(JSON.stringify([altaDe("esperando_huella", { huellas_capturadas: 0, caduca_en: "2099-01-01T00:00:00Z" })])) });
    renderSeccion();
    expect(await screen.findByText("Esperando huella")).toBeInTheDocument();
    expect(screen.getByText(/esperando que ti enrole la huella en la terminal/i)).toBeInTheDocument();
    expect(screen.getByText(/caduca en/i)).toBeInTheDocument();
  });

  it("pendiente de baja explica que reactivar no reenrola", async () => {
    mockApi({ altas: () => new Response(JSON.stringify([altaDe("pendiente_baja")])) });
    renderSeccion();
    expect(await screen.findByText("Pendiente de baja")).toBeInTheDocument();
    expect(screen.getByText(/reactivar a la persona no la reenrola/i)).toBeInTheDocument();
  });

  it("reconsentimiento pendiente: lo señala con la versión que confirmó y aclara que no afecta sus marcas", async () => {
    mockApi({ altas: () => new Response(JSON.stringify([altaDe("activo", { reconsentimiento_pendiente: true, consentimiento: { id: 2, version: 2, provisional: false }, consentimiento_vigente_id: 4 })])) });
    renderSeccion();
    expect(await screen.findByText(/reconsentimiento pendiente/i)).toBeInTheDocument();
    expect(screen.getByText(/no afecta sus marcas/i)).toBeInTheDocument();
    expect(screen.getByText(/v2/)).toBeInTheDocument();
  });

  it("las altas en baja no cuentan como vigentes: se trata como sin asignación", async () => {
    mockApi({ altas: () => new Response(JSON.stringify([altaDe("baja")])) });
    renderSeccion();
    expect(await screen.findByText(/no está asignada a ninguna terminal/i)).toBeInTheDocument();
  });

  it("error: tarjeta propia con Reintentar y aclara que el resto de la ficha sigue disponible", async () => {
    let falla = true;
    mockApi({ altas: () => (falla ? new Response(null, { status: 500 }) : new Response("[]")) });
    renderSeccion();
    expect(await screen.findByText(/no se pudo cargar la información de la terminal/i)).toBeInTheDocument();
    expect(screen.getByText(/el resto de la ficha sigue disponible/i)).toBeInTheDocument();
    falla = false;
    await userEvent.click(screen.getByRole("button", { name: /reintentar/i }));
    expect(await screen.findByText(/no está asignada a ninguna terminal/i)).toBeInTheDocument();
  });

  it("una respuesta con forma inesperada (no es una lista) se trata como error, sin romper la ficha", async () => {
    mockApi({ altas: () => new Response(JSON.stringify({ detail: "raro" })) });
    renderSeccion();
    expect(await screen.findByText(/no se pudo cargar la información de la terminal/i)).toBeInTheDocument();
  });

  it("Asignar a la terminal abre el modal con la persona fija y sólo terminales activas sin alta vigente", async () => {
    mockApi({ altas: () => new Response(JSON.stringify([altaDe("baja")])) });
    renderSeccion();
    await userEvent.click(await screen.findByRole("button", { name: /asignar a la terminal/i }));
    const dialogo = await screen.findByRole("dialog", { name: /asignar persona a la terminal/i });
    expect(within(dialogo).getByText("Ana Torres — Auxiliar de almacén · Bodega")).toBeInTheDocument();
    const selector = within(dialogo).getByLabelText("Terminal");
    expect(within(selector).getByRole("option", { name: "Entrada principal" })).toBeInTheDocument();
    expect(within(selector).getByRole("option", { name: "Bodega" })).toBeInTheDocument();
    expect(within(selector).queryByRole("option", { name: "Vieja" })).not.toBeInTheDocument();
  });

  it("al asignar, recarga la sección", async () => {
    let altas: unknown[] = [];
    mockApi({ altas: () => new Response(JSON.stringify(altas)) });
    renderSeccion();
    await userEvent.click(await screen.findByRole("button", { name: /asignar a la terminal/i }));
    await userEvent.selectOptions(await screen.findByLabelText("Terminal"), "2");
    await userEvent.click(await screen.findByLabelText(/consentimiento y aviso de privacidad recabados/i));
    altas = [altaDe("pendiente_alta", { employee_no: 1100 }, { id: 2, nombre: "Bodega" })];
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
    await userEvent.click(await screen.findByRole("button", { name: /^cerrar$/i }));
    expect(await screen.findByText("Pendiente de alta")).toBeInTheDocument();
  });
});

describe("SeccionTerminalPersona · evidencia de huella y Confirmar huella", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it.each([
    ["inferida", 0, /Huella verificada en el aparato/],
    ["manual", 0, /Huella confirmada por una persona \(sin conteo\)/],
  ])("activa con evidencia %s: etiqueta sin número", async (evidencia, huellas, etiqueta) => {
    mockApi({ altas: () => new Response(JSON.stringify([altaDe("activo", { huella_evidencia: evidencia, huellas_capturadas: huellas })])) });
    renderSeccion();
    expect(await screen.findByText(etiqueta)).toBeInTheDocument();
    expect(screen.queryByText(/0 huellas/)).not.toBeInTheDocument();
  });

  it("regresión: activa con huellas_capturadas = 0 y sin evidencia no pinta «0 huellas» ni nada", async () => {
    mockApi({ altas: () => new Response(JSON.stringify([altaDe("activo", { huella_evidencia: null, huellas_capturadas: 0 })])) });
    renderSeccion();
    expect(await screen.findByText("Activo")).toBeInTheDocument();
    expect(screen.queryByText(/huella/i, { selector: "p" })).not.toBeInTheDocument();
  });

  it("esperando huella con edición: ofrece Confirmar huella, abre el modal y al terminar recarga", async () => {
    let altas = [altaDe("esperando_huella", { huellas_capturadas: 0, huella_evidencia: null, caduca_en: "2099-01-01T00:00:00Z" })];
    mockApi({ altas: () => new Response(JSON.stringify(altas)) });
    const base = vi.mocked(apiFetch).getMockImplementation()!;
    vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
      if (path === "/api/terminales/1/usuarios/10/huella-confirmada" && init?.method === "POST") {
        altas = [altaDe("activo", { huella_evidencia: "manual", huellas_capturadas: 0 })];
        return Promise.resolve(new Response("{}", { status: 201 }));
      }
      return base(path, init);
    });
    renderSeccion();
    await userEvent.click(await screen.findByRole("button", { name: /confirmar huella/i }));
    await userEvent.type(screen.getByLabelText(/nota/i), "TI enroló el índice derecho en el aparato");
    await userEvent.click(screen.getByRole("button", { name: /confirmar que vi la huella/i }));
    await userEvent.click(await screen.findByRole("button", { name: /^cerrar$/i }));
    expect(await screen.findByText(/Huella confirmada por una persona \(sin conteo\)/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /confirmar huella/i })).not.toBeInTheDocument();
  });

  it("sin permiso de edición no ofrece Confirmar huella", async () => {
    mockApi({ sesion: { puede_editar_terminales: false }, altas: () => new Response(JSON.stringify([altaDe("esperando_huella", { huellas_capturadas: 0, huella_evidencia: null })])) });
    renderSeccion();
    expect(await screen.findByText("Esperando huella")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /confirmar huella/i })).not.toBeInTheDocument();
  });

  it("sólo en Esperando huella: la activa no ofrece Confirmar huella", async () => {
    mockApi({ altas: () => new Response(JSON.stringify([altaDe("activo")])) });
    renderSeccion();
    await screen.findByText("Activo");
    expect(screen.queryByRole("button", { name: /confirmar huella/i })).not.toBeInTheDocument();
  });
});

describe("SeccionTerminalPersona · aviso de caducidad (security F1)", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("esperando huella: dice que la confirma una persona y que caduca y se borra, junto a la cuenta regresiva; no promete activación automática", async () => {
    mockApi({ altas: () => new Response(JSON.stringify([altaDe("esperando_huella", { huellas_capturadas: 0, huella_evidencia: null, caduca_en: "2099-01-01T00:00:00Z" })])) });
    renderSeccion();
    const aviso = await screen.findByText(/la confirma una persona con «confirmar huella»/i);
    expect(aviso).toHaveTextContent(/si no se confirma antes de que caduque, el alta se da de baja y se borra del aparato/i);
    expect(screen.queryByText(/se activa sola/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/primera marca/i)).not.toBeInTheDocument();
    expect(screen.getByText(/caduca en/i)).toBeInTheDocument();
  });
});
