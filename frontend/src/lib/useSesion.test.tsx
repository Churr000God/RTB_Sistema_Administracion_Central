import { renderHook, waitFor } from "@testing-library/react";
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

  it("si /api/sesion falla, sesion es null y no queda cargando (la UI decide el fail-open)", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.reject(new Error("red")));
    const { result } = renderHook(() => useSesion());
    await waitFor(() => expect(result.current.cargando).toBe(false));
    expect(result.current.sesion).toBeNull();
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
