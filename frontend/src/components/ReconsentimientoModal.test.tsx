import { fireEvent, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { ReconsentimientoModal } from "./ReconsentimientoModal";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));

const TEXTO_V4 = "Texto vigente v4 de consentimiento.";
const VIGENTE = (extra: Record<string, unknown> = {}) => ({
  id: 4,
  version: 4,
  texto: TEXTO_V4,
  provisional: false,
  cambio_material: true,
  vigente_desde: "2026-10-08T12:00:00Z",
  ...extra,
});

const UNA = [{ id: 77, persona_nombre: "Pedro Salas" }];
const DOS = [{ id: 77, persona_nombre: "Pedro Salas" }, { id: 81, persona_nombre: "Elena Ríos" }];

type Config = { consentimiento?: () => Response; post?: (ruta: string, cuerpo: Record<string, unknown>) => Response };

function mockApi(config: Config = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/terminales/configuracion/consentimiento") {
      return Promise.resolve(config.consentimiento?.() ?? new Response(JSON.stringify({ vigente: VIGENTE(), historial: [] })));
    }
    if (init?.method === "POST") {
      const cuerpo = JSON.parse(init.body as string);
      return Promise.resolve(config.post?.(path, cuerpo) ?? new Response(JSON.stringify({ registradas: cuerpo.tu_ids?.length ?? 1, pendientes_restantes: 12, omitidas: [] }), { status: 201 }));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

function postsHechos() {
  return vi.mocked(apiFetch).mock.calls.filter(([, init]) => init?.method === "POST");
}

async function listo() {
  await screen.findByText(TEXTO_V4);
}

describe("ReconsentimientoModal", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("muestra la versión y el TEXTO completo antes de la confirmación de los documentos firmados", async () => {
    mockApi();
    render(<ReconsentimientoModal terminalId={1} altas={UNA} onCerrar={vi.fn()} />);
    await listo();
    expect(screen.getByText(/versión 4/i, { selector: "h4" })).toBeInTheDocument();
    expect(screen.getByText(/cambio material/i, { selector: "h4" })).toBeInTheDocument();
    expect(screen.getByLabelText(/confirmo que los documentos firmados existen/i)).not.toBeChecked();
    expect(screen.getByText(/no reenrola ninguna huella/i)).toBeInTheDocument();
  });

  it("el texto del servidor se pinta como texto plano", async () => {
    mockApi({ consentimiento: () => new Response(JSON.stringify({ vigente: VIGENTE({ texto: "<img src=x onerror=alert(1)>" }), historial: [] })) });
    const { baseElement } = render(<ReconsentimientoModal terminalId={1} altas={UNA} onCerrar={vi.fn()} />);
    expect(await screen.findByText("<img src=x onerror=alert(1)>")).toBeInTheDocument();
    expect(baseElement.querySelector("img[src='x']")).toBeNull();
  });

  it("sin marcar la declaración no envía y marca el campo", async () => {
    mockApi();
    render(<ReconsentimientoModal terminalId={1} altas={UNA} onCerrar={vi.fn()} />);
    await listo();
    await userEvent.click(screen.getByRole("button", { name: /registrar reconsentimiento/i }));
    expect(postsHechos()).toHaveLength(0);
    expect(screen.getByText(/confirma que existen los documentos firmados/i)).toBeInTheDocument();
  });

  it("una alta: POST por alta con consentimiento_id y declaracion_documentos", async () => {
    mockApi();
    const onCerrar = vi.fn();
    render(<ReconsentimientoModal terminalId={1} altas={UNA} onCerrar={onCerrar} />);
    await listo();
    await userEvent.click(screen.getByLabelText(/confirmo que los documentos firmados existen/i));
    await userEvent.click(screen.getByRole("button", { name: /registrar reconsentimiento/i }));
    expect(await screen.findByText(/reconsentimiento registrado/i)).toBeInTheDocument();
    const [ruta, init] = postsHechos()[0];
    expect(ruta).toBe("/api/terminales/1/usuarios/77/reconsentimiento");
    expect(JSON.parse(init!.body as string)).toEqual({ consentimiento_id: 4, declaracion_documentos: true });
    await userEvent.click(screen.getByRole("button", { name: /^cerrar$/i }));
    expect(onCerrar).toHaveBeenCalledWith(true);
  });

  it("lote: POST con tu_ids sin duplicados, y avisa cuántas quedan pendientes", async () => {
    mockApi();
    render(<ReconsentimientoModal terminalId={1} altas={[...DOS, DOS[0]]} onCerrar={vi.fn()} />);
    await listo();
    expect(screen.getAllByText(/2 personas/i).length).toBeGreaterThan(0);
    expect(screen.getByText(/Pedro Salas, Elena Ríos/)).toBeInTheDocument();
    await userEvent.click(screen.getByLabelText(/confirmo que los documentos firmados existen/i));
    await userEvent.click(screen.getByRole("button", { name: /registrar reconsentimiento/i }));
    expect(await screen.findByText(/quedan 12 pendientes/i)).toBeInTheDocument();
    const [ruta, init] = postsHechos()[0];
    expect(ruta).toBe("/api/terminales/1/usuarios/reconsentimientos");
    expect(JSON.parse(init!.body as string)).toEqual({ tu_ids: [77, 81], consentimiento_id: 4, declaracion_documentos: true });
  });

  it("más de 200 altas: el botón queda inerte con el motivo y no envía", async () => {
    mockApi();
    const muchas = Array.from({ length: 201 }, (_, i) => ({ id: i + 1, persona_nombre: `P${i}` }));
    render(<ReconsentimientoModal terminalId={1} altas={muchas} onCerrar={vi.fn()} />);
    await listo();
    expect(screen.getByText(/máximo es 200 por vez/i)).toBeInTheDocument();
    await userEvent.click(screen.getByLabelText(/confirmo que los documentos firmados existen/i));
    expect(screen.getByRole("button", { name: /registrar reconsentimiento/i })).toBeDisabled();
    expect(postsHechos()).toHaveLength(0);
  });

  it("409 con no_elegibles: nada se registró, lista las razones fijas y no manda a ciegas otra vez", async () => {
    mockApi({
      post: () =>
        new Response(JSON.stringify({ detail: "No se registró nada: algunas altas ya no son elegibles.", no_elegibles: [{ tu_id: 81, persona_nombre: "Elena Ríos", razon: "ya_al_corriente" }, { tu_id: 90, persona_nombre: "María López", razon: "es_propia" }, { tu_id: 99, razon: "no_encontrada" }] }), { status: 409 }),
    });
    render(<ReconsentimientoModal terminalId={1} altas={DOS} onCerrar={vi.fn()} />);
    await listo();
    await userEvent.click(screen.getByLabelText(/confirmo que los documentos firmados existen/i));
    await userEvent.click(screen.getByRole("button", { name: /registrar reconsentimiento/i }));
    const alerta = await screen.findByRole("alert");
    expect(alerta).toHaveTextContent(/no se registró nada/i);
    expect(within(alerta).getByText("Elena Ríos")).toBeInTheDocument();
    expect(within(alerta).getByText(/ya estaba al corriente/i)).toBeInTheDocument();
    expect(within(alerta).getByText(/no puedes registrar tu propio reconsentimiento/i)).toBeInTheDocument();
    expect(within(alerta).getByText(/la alta ya no existe en esta terminal/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /actualizar lista/i })).toBeInTheDocument();
  });

  it("una razón desconocida no rompe: muestra un texto genérico", async () => {
    mockApi({ post: () => new Response(JSON.stringify({ detail: "x", no_elegibles: [{ tu_id: 1, persona_nombre: "Z", razon: "razon_nueva" }] }), { status: 409 }) });
    render(<ReconsentimientoModal terminalId={1} altas={UNA} onCerrar={vi.fn()} />);
    await listo();
    await userEvent.click(screen.getByLabelText(/confirmo que los documentos firmados existen/i));
    await userEvent.click(screen.getByRole("button", { name: /registrar reconsentimiento/i }));
    expect(await screen.findByText(/no es elegible ahora/i)).toBeInTheDocument();
  });

  it("409 de texto desactualizado: toma la versión nueva, DESMARCA la declaración y pide releer", async () => {
    mockApi({
      post: () => new Response(JSON.stringify({ detail: "El texto de consentimiento cambió…", consentimiento_vigente: VIGENTE({ id: 5, version: 5, texto: "Texto v5" }) }), { status: 409 }),
    });
    render(<ReconsentimientoModal terminalId={1} altas={UNA} onCerrar={vi.fn()} />);
    await listo();
    await userEvent.click(screen.getByLabelText(/confirmo que los documentos firmados existen/i));
    await userEvent.click(screen.getByRole("button", { name: /registrar reconsentimiento/i }));
    expect(await screen.findByText("Texto v5")).toBeInTheDocument();
    expect(screen.getByLabelText(/confirmo que los documentos firmados existen/i)).not.toBeChecked();
    const antes = postsHechos().length;
    await userEvent.click(screen.getByRole("button", { name: /registrar reconsentimiento/i }));
    expect(postsHechos()).toHaveLength(antes);
  });

  it("409 de texto con consentimiento_vigente incompleto: vuelve a leer y desmarca", async () => {
    let lecturas = 0;
    vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
      if (path === "/api/terminales/configuracion/consentimiento") {
        lecturas++;
        return Promise.resolve(new Response(JSON.stringify({ vigente: VIGENTE(lecturas > 1 ? { id: 7, version: 7, texto: "Texto releído v7" } : {}), historial: [] })));
      }
      return Promise.resolve(new Response(JSON.stringify({ detail: "El texto de consentimiento cambió…", codigo: "consentimiento_desactualizado", consentimiento_vigente: { version: 7 } }), { status: 409 }));
    });
    render(<ReconsentimientoModal terminalId={1} altas={UNA} onCerrar={vi.fn()} />);
    await listo();
    await userEvent.click(screen.getByLabelText(/confirmo que los documentos firmados existen/i));
    await userEvent.click(screen.getByRole("button", { name: /registrar reconsentimiento/i }));
    expect(await screen.findByText("Texto releído v7")).toBeInTheDocument();
    expect(screen.getByLabelText(/confirmo que los documentos firmados existen/i)).not.toBeChecked();
    expect(lecturas).toBe(2);
  });

  it("el código lote_no_elegible marca conflicto (Actualizar lista) aunque el cuerpo no traiga la lista", async () => {
    mockApi({ post: () => new Response(JSON.stringify({ detail: "No se registró nada.", codigo: "lote_no_elegible" }), { status: 409 }) });
    render(<ReconsentimientoModal terminalId={1} altas={UNA} onCerrar={vi.fn()} />);
    await listo();
    await userEvent.click(screen.getByLabelText(/confirmo que los documentos firmados existen/i));
    await userEvent.click(screen.getByRole("button", { name: /registrar reconsentimiento/i }));
    expect(await screen.findByRole("button", { name: /actualizar lista/i })).toBeInTheDocument();
  });

  it.each([
    [403, { detail: "No tienes permiso para esta acción." }, /no tienes permiso para esta acción/i],
    [422, { detail: "No puedes registrar tu propio reconsentimiento; lo registra otra persona con permiso." }, /no puedes registrar tu propio reconsentimiento/i],
    [503, { detail: "interno" }, /servicio no disponible; reintenta/i],
    [500, { detail: "tabla tiempo.x" }, /no se pudo registrar/i],
  ])("error %i usa el mensaje fijo o el propio, nunca texto interno", async (status, cuerpo, esperado) => {
    mockApi({ post: () => new Response(JSON.stringify(cuerpo), { status }) });
    render(<ReconsentimientoModal terminalId={1} altas={UNA} onCerrar={vi.fn()} />);
    await listo();
    await userEvent.click(screen.getByLabelText(/confirmo que los documentos firmados existen/i));
    await userEvent.click(screen.getByRole("button", { name: /registrar reconsentimiento/i }));
    const alerta = await screen.findByRole("alert");
    expect(alerta).toHaveTextContent(esperado);
    expect(alerta).not.toHaveTextContent(/tabla tiempo|interno/);
  });

  it("mientras envía bloquea todo y evita el doble envío", async () => {
    mockApi();
    let resolver!: (r: Response) => void;
    const anterior = vi.mocked(apiFetch).getMockImplementation()!;
    vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) =>
      init?.method === "POST" ? new Promise<Response>((r) => (resolver = r)) : anterior(path, init),
    );
    render(<ReconsentimientoModal terminalId={1} altas={UNA} onCerrar={vi.fn()} />);
    await listo();
    await userEvent.click(screen.getByLabelText(/confirmo que los documentos firmados existen/i));
    await userEvent.click(screen.getByRole("button", { name: /registrar reconsentimiento/i }));
    expect(screen.getByRole("button", { name: /registrando/i })).toBeDisabled();
    expect(screen.getByRole("button", { name: /cancelar/i })).toBeDisabled();
    expect(screen.getByLabelText(/confirmo que los documentos firmados existen/i)).toBeDisabled();
    expect(postsHechos()).toHaveLength(1);
    resolver(new Response(JSON.stringify({ registradas: 1 }), { status: 201 }));
    await screen.findByText(/reconsentimiento registrado/i);
  });

  it("no se pudo cargar el texto: Registrar inerte y Reintentar", async () => {
    let falla = true;
    mockApi({ consentimiento: () => (falla ? new Response(null, { status: 500 }) : new Response(JSON.stringify({ vigente: VIGENTE(), historial: [] }))) });
    render(<ReconsentimientoModal terminalId={1} altas={UNA} onCerrar={vi.fn()} />);
    expect(await screen.findByText(/no se pudo cargar el texto de consentimiento/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /registrar reconsentimiento/i })).toBeDisabled();
    falla = false;
    await userEvent.click(screen.getByRole("button", { name: /reintentar/i }));
    await listo();
  });

  it("Cancelar y Escape cierran sin refrescar; Actualizar lista tras un 409 sí refresca", async () => {
    mockApi({ post: () => new Response(JSON.stringify({ detail: "x", no_elegibles: [{ tu_id: 1, razon: "en_baja" }] }), { status: 409 }) });
    const onCerrar = vi.fn();
    render(<ReconsentimientoModal terminalId={1} altas={UNA} onCerrar={onCerrar} />);
    await listo();
    fireEvent(screen.getByRole("dialog"), new Event("cancel", { cancelable: true }));
    expect(onCerrar).toHaveBeenCalledWith(false);
    onCerrar.mockClear();
    await userEvent.click(screen.getByLabelText(/confirmo que los documentos firmados existen/i));
    await userEvent.click(screen.getByRole("button", { name: /registrar reconsentimiento/i }));
    await userEvent.click(await screen.findByRole("button", { name: /actualizar lista/i }));
    expect(onCerrar).toHaveBeenCalledWith(true);
  });
});
