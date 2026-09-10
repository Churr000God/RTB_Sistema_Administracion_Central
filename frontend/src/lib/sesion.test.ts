import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "./apiClient";
import { consultarSesion } from "./sesion";

vi.mock("./apiClient", () => ({ apiFetch: vi.fn() }));

describe("consultarSesion", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("deduplica invocaciones concurrentes: dos llamadas producen una sola petición", async () => {
    // Simula el doble-mount de StrictMode: dos invocaciones en la misma pasada síncrona,
    // antes de que ninguna haya tenido chance de resolver.
    vi.mocked(apiFetch).mockResolvedValue(
      new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
    );

    const [a, b] = await Promise.all([consultarSesion(), consultarSesion()]);

    expect(apiFetch).toHaveBeenCalledTimes(1);
    expect(a).toEqual(b);
    expect(a.acceso_permitido).toBe(true);
  });

  it("una vez resuelta, la siguiente invocación dispara una petición nueva (no cachea para siempre)", async () => {
    vi.mocked(apiFetch).mockImplementation(() =>
      Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      )
    );

    await consultarSesion();
    await consultarSesion();

    expect(apiFetch).toHaveBeenCalledTimes(2);
  });

  it("un error HTTP se propaga como excepción, para que el llamador haga fail-open", async () => {
    vi.mocked(apiFetch).mockResolvedValue(new Response(null, { status: 500 }));

    await expect(consultarSesion()).rejects.toThrow();
  });

  it("dos llamadas concurrentes que fallan comparten el mismo rechazo, no disparan dos peticiones", async () => {
    vi.mocked(apiFetch).mockRejectedValue(new Error("network down"));

    const resultados = await Promise.allSettled([consultarSesion(), consultarSesion()]);

    expect(apiFetch).toHaveBeenCalledTimes(1);
    expect(resultados[0].status).toBe("rejected");
    expect(resultados[1].status).toBe("rejected");
  });
});
