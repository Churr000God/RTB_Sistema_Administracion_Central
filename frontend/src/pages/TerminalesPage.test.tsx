import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { TerminalesPage } from "./TerminalesPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const ENTRADA = {
  id: 1,
  serie: "DS-K1T-0001",
  nombre: "Entrada principal",
  modelo: "DS-K1A8503EF-B",
  activa: true,
  estado_contacto: "en_linea",
  ultimo_contacto_en: "2026-10-08T15:00:00Z",
  segundos_sin_contacto: 40,
  terminal_alcanzable: true,
  reloj_desfase_seg: 2,
  version_pi: "1.4.0",
  marcas_pendientes: 0,
};
const BODEGA = {
  ...ENTRADA,
  id: 2,
  serie: "DS-K1T-0002",
  nombre: "Bodega",
  estado_contacto: "sin_contacto",
  segundos_sin_contacto: 1080,
  terminal_alcanzable: false,
  reloj_desfase_seg: 95,
  marcas_pendientes: 7,
};
const RETIRADA = {
  ...ENTRADA,
  id: 3,
  serie: "DS-K1T-0003",
  nombre: "Oficina (retirada)",
  activa: false,
  estado_contacto: "inactiva",
  ultimo_contacto_en: null,
  segundos_sin_contacto: null,
  terminal_alcanzable: null,
  reloj_desfase_seg: null,
  version_pi: null,
};
const NUNCA = { ...RETIRADA, id: 4, nombre: "Nueva", activa: true, estado_contacto: "nunca" };

function mockApi(opciones: { terminales?: Response; sesion?: Record<string, unknown> | Response } = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") {
      const sesion = opciones.sesion;
      if (sesion instanceof Response) return Promise.resolve(sesion);
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, puede_ver_terminales: true, ...sesion })),
      );
    }
    if (path === "/api/terminales") {
      return Promise.resolve(opciones.terminales ?? new Response(JSON.stringify([ENTRADA, BODEGA, RETIRADA])));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

describe("TerminalesPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
    window.history.replaceState(null, "", "/tiempo/terminales");
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("lista las terminales con contacto (icono+texto), alcanzable, desfase, versión y marcas pendientes", async () => {
    mockApi();
    render(<TerminalesPage />);

    const fila = (await screen.findByText("Entrada principal")).closest("tr")!;
    expect(within(fila).getByText("DS-K1T-0001")).toBeInTheDocument();
    expect(within(fila).getByText("En línea")).toBeInTheDocument();
    expect(within(fila).getByText("hace 40 s")).toBeInTheDocument();
    expect(within(fila).getByText("Sí")).toBeInTheDocument();
    expect(within(fila).getByText("+2 s")).toBeInTheDocument();
    expect(within(fila).getByText("1.4.0")).toBeInTheDocument();

    const bodega = screen.getByText("Bodega").closest("tr")!;
    expect(within(bodega).getByText("Sin contacto")).toBeInTheDocument();
    expect(within(bodega).getByText("hace 18 min")).toBeInTheDocument();
    expect(within(bodega).getByText("No se ve")).toBeInTheDocument();
    expect(within(bodega).getByText("7")).toBeInTheDocument();

    const retirada = screen.getByText("Oficina (retirada)").closest("tr")!;
    expect(within(retirada).getByText("Inactiva")).toBeInTheDocument();
  });

  it("una terminal que nunca se comunicó dice «Sin conexión todavía»", async () => {
    mockApi({ terminales: new Response(JSON.stringify([NUNCA])) });
    render(<TerminalesPage />);
    expect(await screen.findByText("Sin conexión todavía")).toBeInTheDocument();
  });

  it("cada terminal enlaza a sus usuarios", async () => {
    mockApi();
    render(<TerminalesPage />);
    const fila = (await screen.findByText("Bodega")).closest("tr")!;
    expect(within(fila).getByRole("link", { name: /usuarios/i })).toHaveAttribute(
      "href",
      "/tiempo/terminales/2/usuarios",
    );
  });

  it("resume cuántas están en línea, sin contacto y con marcas pendientes", async () => {
    mockApi();
    render(<TerminalesPage />);
    await screen.findByText("Bodega");
    const banda = screen.getByText("En línea", { selector: ".etiqueta-metrica" }).closest(".metrica")!;
    expect(within(banda as HTMLElement).getByText("1")).toBeInTheDocument();
    const pendientes = screen.getByText(/con marcas pendientes/i).closest(".metrica")!;
    expect(within(pendientes as HTMLElement).getByText("1")).toBeInTheDocument();
  });

  it("el texto del servidor se pinta como texto plano, nunca como HTML", async () => {
    mockApi({ terminales: new Response(JSON.stringify([{ ...ENTRADA, nombre: "<img src=x onerror=alert(1)>" }])) });
    const { container } = render(<TerminalesPage />);
    expect(await screen.findByText("<img src=x onerror=alert(1)>")).toBeInTheDocument();
    expect(container.querySelector("img[src='x']")).toBeNull();
  });

  it("una respuesta con forma inesperada se trata como error, no rompe la página", async () => {
    mockApi({ terminales: new Response(JSON.stringify({ detail: "raro" })) });
    render(<TerminalesPage />);
    expect(await screen.findByText(/no se pudo cargar las terminales/i)).toBeInTheDocument();
  });

  it("muestra estado vacío, de error con Reintentar y de carga", async () => {
    mockApi({ terminales: new Response(JSON.stringify([])) });
    const { unmount } = render(<TerminalesPage />);
    expect(await screen.findByText(/todavía no hay terminales dadas de alta/i)).toBeInTheDocument();
    unmount();

    mockApi({ terminales: new Response(null, { status: 500 }) });
    render(<TerminalesPage />);
    expect(await screen.findByText(/no se pudo cargar las terminales/i)).toBeInTheDocument();
    mockApi();
    await userEvent.click(screen.getByRole("button", { name: /reintentar/i }));
    expect(await screen.findByText("Entrada principal")).toBeInTheDocument();
  });

  it("muestra «Cargando terminales…» mientras responde", async () => {
    // /api/sesion responde (si quedara colgada, consultarSesion deduplicaría esa promesa para siempre)
    vi.mocked(apiFetch).mockImplementation((path: string) =>
      path === "/api/sesion"
        ? Promise.resolve(new Response(JSON.stringify({ acceso_permitido: true, puede_ver_terminales: true })))
        : new Promise<Response>(() => {}),
    );
    render(<TerminalesPage />);
    expect(await screen.findByText(/cargando terminales/i)).toBeInTheDocument();
  });

  it("sin puede_ver_terminales muestra el estado sin acceso y no pide terminales", async () => {
    mockApi({ sesion: { puede_ver_terminales: false } });
    render(<TerminalesPage />);
    expect(await screen.findByText(/no tienes acceso a las terminales/i)).toBeInTheDocument();
    expect(vi.mocked(apiFetch).mock.calls.filter(([ruta]) => ruta === "/api/terminales")).toHaveLength(0);
  });

  it("si /api/sesion falla, intenta cargar igual (fail-open; la autorización real es el backend)", async () => {
    mockApi({ sesion: new Response(null, { status: 500 }) });
    render(<TerminalesPage />);
    expect(await screen.findByText("Entrada principal")).toBeInTheDocument();
  });

  it("un 403 del backend se muestra como sin acceso", async () => {
    mockApi({ terminales: new Response(JSON.stringify({ detail: "No tienes permiso para esta acción." }), { status: 403 }) });
    render(<TerminalesPage />);
    expect(await screen.findByText(/no tienes acceso a las terminales/i)).toBeInTheDocument();
  });

  it("terminal alcanzable: Sí / No se ve / —, y el punto de «En línea» es verde", async () => {
    mockApi({ terminales: new Response(JSON.stringify([ENTRADA, BODEGA, NUNCA])) });
    render(<TerminalesPage />);
    const entrada = (await screen.findByText("Entrada principal")).closest("tr")!;
    expect(within(entrada).getByText("Sí")).toBeInTheDocument();
    expect(entrada.querySelector(".punto.punto--exito")).not.toBeNull();
    const bodega = screen.getByText("Bodega").closest("tr")!;
    expect(within(bodega).getByText("No se ve")).toBeInTheDocument();
    expect(bodega.querySelector(".punto.punto--aviso")).not.toBeNull();
    const nueva = screen.getByText("Nueva").closest("tr")!;
    expect(within(nueva).queryByText("Sí")).not.toBeInTheDocument();
    expect(within(nueva).queryByText("No se ve")).not.toBeInTheDocument();
  });

  it("«las altas siguen esperando» sólo en sin_contacto", async () => {
    mockApi({ terminales: new Response(JSON.stringify([ENTRADA, BODEGA, NUNCA, RETIRADA])) });
    render(<TerminalesPage />);
    await screen.findByText("Bodega");
    expect(screen.getAllByText(/las altas siguen esperando/i)).toHaveLength(1);
    expect(within(screen.getByText("Bodega").closest("tr")!).getByText(/las altas siguen esperando/i)).toBeInTheDocument();
  });

  it("el resumen cuenta sin_contacto y no «nunca» (1 nunca + 1 sin_contacto ⇒ 1)", async () => {
    mockApi({ terminales: new Response(JSON.stringify([NUNCA, { ...BODEGA, marcas_pendientes: 0 }])) });
    render(<TerminalesPage />);
    await screen.findByText("Bodega");
    const sinContacto = screen.getByText("Sin contacto", { selector: ".etiqueta-metrica" }).closest(".metrica") as HTMLElement;
    expect(within(sinContacto).getByText("1")).toBeInTheDocument();
    const enLinea = screen.getByText("En línea", { selector: ".etiqueta-metrica" }).closest(".metrica") as HTMLElement;
    expect(within(enLinea).getByText("0")).toBeInTheDocument();
  });

  it("un refresco silencioso que falla NO tira la lista que ya se ve", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    let llamadas = 0;
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") return Promise.resolve(new Response(JSON.stringify({ acceso_permitido: true, puede_ver_terminales: true })));
      llamadas++;
      return Promise.resolve(llamadas === 1 ? new Response(JSON.stringify([ENTRADA])) : new Response(null, { status: 500 }));
    });
    render(<TerminalesPage />);
    await screen.findByText("Entrada principal");
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60_000);
    });
    expect(llamadas).toBeGreaterThanOrEqual(2);
    expect(screen.getByText("Entrada principal")).toBeInTheDocument();
    expect(screen.queryByText(/no se pudo cargar las terminales/i)).not.toBeInTheDocument();
  });

  it("el refresco se detiene al desmontar la página", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    mockApi();
    const { unmount } = render(<TerminalesPage />);
    await screen.findByText("Entrada principal");
    unmount();
    const antes = vi.mocked(apiFetch).mock.calls.filter(([p]) => p === "/api/terminales").length;
    await act(async () => {
      await vi.advanceTimersByTimeAsync(180_000);
    });
    expect(vi.mocked(apiFetch).mock.calls.filter(([p]) => p === "/api/terminales").length).toBe(antes);
  });

  it("se refresca solo cada 60 s", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    mockApi();
    render(<TerminalesPage />);
    await vi.waitFor(() =>
      expect(vi.mocked(apiFetch).mock.calls.filter(([p]) => p === "/api/terminales")).toHaveLength(1),
    );
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60_000);
    });
    expect(vi.mocked(apiFetch).mock.calls.filter(([p]) => p === "/api/terminales").length).toBeGreaterThanOrEqual(2);
  });
});
