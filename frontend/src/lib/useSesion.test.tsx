import { act, renderHook, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "./apiClient";
import { useSesion } from "./useSesion";

vi.mock("./apiClient", () => ({ apiFetch: vi.fn() }));

describe("useSesion", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("carga la sesión y expone las banderas", async () => {
    vi.mocked(apiFetch).mockResolvedValue(
      new Response(JSON.stringify({ acceso_permitido: true, puede_ver_terminales: true, puede_editar_terminales: false })),
    );
    const { result } = renderHook(() => useSesion());
    expect(result.current.cargando).toBe(true);
    await waitFor(() => expect(result.current.cargando).toBe(false));
    expect(result.current.sesion?.puede_ver_terminales).toBe(true);
    expect(result.current.sesion?.puede_editar_terminales).toBe(false);
  });

  it("si /api/sesion falla (tras los reintentos): sesion null, error expuesto y NO hay sesión utilizable (cargando)", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.reject(new Error("red")));
    const { result } = renderHook(() => useSesion());
    await waitFor(() => expect(result.current.error).not.toBeNull());
    expect(result.current.sesion).toBeNull();
    expect(result.current.error?.status).toBeNull();
    // nada debe pedir sus datos con una sesión que no se pudo verificar
    expect(result.current.cargando).toBe(true);
    expect(apiFetch).toHaveBeenCalledTimes(3);
  });

  it("5xx: error con el status; 401: error sin reintentos", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(null, { status: 401 })));
    const { result } = renderHook(() => useSesion());
    await waitFor(() => expect(result.current.error?.status).toBe(401));
    expect(apiFetch).toHaveBeenCalledTimes(1);
  });

  it("reintentar() vuelve a pedir y, si responde, limpia el error", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(null, { status: 503 })));
    const { result } = renderHook(() => useSesion());
    await waitFor(() => expect(result.current.error).not.toBeNull());
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(JSON.stringify({ acceso_permitido: true }))));
    act(() => result.current.reintentar());
    await waitFor(() => expect(result.current.sesion).not.toBeNull());
    expect(result.current.error).toBeNull();
    expect(result.current.cargando).toBe(false);
  });

  it("si la página se desmonta antes de que responda /api/sesion, no actualiza estado ni falla", async () => {
    const errores = vi.spyOn(console, "error").mockImplementation(() => {});
    let responder!: (r: Response) => void;
    vi.mocked(apiFetch).mockImplementation(() => new Promise<Response>((r) => (responder = r)));
    const { result, unmount } = renderHook(() => useSesion());
    unmount();
    responder(new Response(JSON.stringify({ acceso_permitido: true })));
    await new Promise((r) => setTimeout(r, 20));
    expect(result.current.cargando).toBe(true);
    expect(errores).not.toHaveBeenCalled();
    errores.mockRestore();
  });
});

describe("useSesion · varias instancias", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("reintentar() en una instancia refresca a las demás (la página y el AppShell se recuperan juntos) con una sola petición", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(null, { status: 503 })));
    const a = renderHook(() => useSesion());
    const b = renderHook(() => useSesion());
    await waitFor(() => expect(a.result.current.error).not.toBeNull());
    await waitFor(() => expect(b.result.current.error).not.toBeNull());
    vi.mocked(apiFetch).mockReset();
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(JSON.stringify({ acceso_permitido: true }))));
    act(() => a.result.current.reintentar());
    await waitFor(() => expect(a.result.current.sesion).not.toBeNull());
    await waitFor(() => expect(b.result.current.sesion).not.toBeNull());
    expect(b.result.current.error).toBeNull();
    expect(apiFetch).toHaveBeenCalledTimes(1);
  });
});
