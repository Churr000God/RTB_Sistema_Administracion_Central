import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "./apiClient";
import {
  configurarPausasDeReintento,
  consultarSesion,
  consultarSesionConReintento,
  ErrorSesion,
  esReintentable,
} from "./sesion";

vi.mock("./apiClient", () => ({ apiFetch: vi.fn() }));

const OK = () => Promise.resolve(new Response(JSON.stringify({ acceso_permitido: true })));

describe("consultarSesion / consultarSesionConReintento", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
    configurarPausasDeReintento([0, 0]);
  });

  afterEach(() => {
    vi.useRealTimers();
    configurarPausasDeReintento([0, 0]);
  });

  it("consultarSesion no reintenta: un 500 es un ErrorSesion con su status", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(null, { status: 500 })));
    await expect(consultarSesion()).rejects.toMatchObject({ name: "ErrorSesion", status: 500 });
    expect(apiFetch).toHaveBeenCalledTimes(1);
  });

  it("falla de red => ErrorSesion con status null; cuerpo no JSON también", async () => {
    vi.mocked(apiFetch).mockRejectedValue(new Error("red"));
    await expect(consultarSesion()).rejects.toMatchObject({ status: null });
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response("<html>", { status: 200 })));
    await expect(consultarSesion()).rejects.toMatchObject({ status: null });
  });

  it("con reintento: 3 intentos en total ante 5xx o red, y luego falla con el último error", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(null, { status: 502 })));
    await expect(consultarSesionConReintento()).rejects.toMatchObject({ status: 502 });
    expect(apiFetch).toHaveBeenCalledTimes(3);
  });

  it("se recupera si un intento posterior responde, sin error", async () => {
    vi.mocked(apiFetch).mockResolvedValueOnce(new Response(null, { status: 500 })).mockRejectedValueOnce(new Error("red")).mockImplementation(OK);
    await expect(consultarSesionConReintento()).resolves.toMatchObject({ acceso_permitido: true });
    expect(apiFetch).toHaveBeenCalledTimes(3);
  });

  it.each([[401], [403], [404], [422]])("un %i no se reintenta", async (status) => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(null, { status })));
    await expect(consultarSesionConReintento()).rejects.toMatchObject({ status });
    expect(apiFetch).toHaveBeenCalledTimes(1);
  });

  it("respeta las pausas configuradas entre intentos (backoff)", async () => {
    vi.useFakeTimers();
    configurarPausasDeReintento([500, 1500]);
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(null, { status: 500 })));
    const resultado = consultarSesionConReintento().catch((e) => e);
    await vi.advanceTimersByTimeAsync(0);
    expect(apiFetch).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(499);
    expect(apiFetch).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(apiFetch).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(1499);
    expect(apiFetch).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(apiFetch).toHaveBeenCalledTimes(3);
    expect(await resultado).toBeInstanceOf(ErrorSesion);
  });

  it("tiempo agotado (la petición no responde en 10 s): ErrorSesion sin status", async () => {
    vi.useFakeTimers();
    configurarPausasDeReintento([]);
    vi.mocked(apiFetch).mockImplementation(() => new Promise<Response>(() => {}));
    const resultado = consultarSesionConReintento().catch((e) => e);
    await vi.advanceTimersByTimeAsync(10_000);
    const error = await resultado;
    expect(error).toBeInstanceOf(ErrorSesion);
    expect((error as ErrorSesion).status).toBeNull();
  });

  it("dos consultas simultáneas comparten la misma petición (reintentos incluidos)", async () => {
    vi.mocked(apiFetch).mockImplementation(OK);
    const [a, b] = await Promise.all([consultarSesionConReintento(), consultarSesionConReintento()]);
    expect(a).toEqual(b);
    expect(apiFetch).toHaveBeenCalledTimes(1);
  });

  it("esReintentable: sólo red/tiempo y 5xx", () => {
    expect(esReintentable(new ErrorSesion(null))).toBe(true);
    expect(esReintentable(new ErrorSesion(500))).toBe(true);
    expect(esReintentable(new ErrorSesion(503))).toBe(true);
    expect(esReintentable(new ErrorSesion(401))).toBe(false);
    expect(esReintentable(new ErrorSesion(429))).toBe(false);
    expect(esReintentable(new Error("x"))).toBe(false);
  });
});

describe("Retry-After del backend (503)", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  afterEach(() => {
    vi.useRealTimers();
    configurarPausasDeReintento([0, 0]);
  });

  const r503 = (retryAfter: string | null) =>
    Promise.resolve(new Response(JSON.stringify({ detail: "x" }), { status: 503, headers: retryAfter === null ? {} : { "Retry-After": retryAfter } }));

  it("un 503 es «no se sabe»: error con status 503 y la espera pedida, nunca una sesión", async () => {
    configurarPausasDeReintento([]);
    vi.mocked(apiFetch).mockImplementation(() => r503("2"));
    await expect(consultarSesionConReintento()).rejects.toMatchObject({ status: 503, esperaMs: 2000 });
  });

  it("espera lo que pide Retry-After (2 s) aunque la pausa corta sea menor, y reintenta", async () => {
    vi.useFakeTimers();
    configurarPausasDeReintento([100, 100]);
    vi.mocked(apiFetch).mockImplementation(() => r503("2"));
    const resultado = consultarSesionConReintento().catch((e) => e);
    await vi.advanceTimersByTimeAsync(0);
    expect(apiFetch).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1999);
    expect(apiFetch).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(apiFetch).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(2000);
    expect(apiFetch).toHaveBeenCalledTimes(3);
    expect(await resultado).toBeInstanceOf(ErrorSesion);
  });

  it("sin Retry-After usa la pausa corta; uno enorme se acota a 5 s; uno ilegible se ignora", async () => {
    vi.mocked(apiFetch).mockImplementation(() => r503("3600"));
    configurarPausasDeReintento([]);
    await expect(consultarSesionConReintento()).rejects.toMatchObject({ esperaMs: 5000 });
    vi.mocked(apiFetch).mockImplementation(() => r503("Wed, 21 Oct 2026 07:28:00 GMT"));
    await expect(consultarSesionConReintento()).rejects.toMatchObject({ esperaMs: null });
    vi.mocked(apiFetch).mockImplementation(() => r503(null));
    await expect(consultarSesionConReintento()).rejects.toMatchObject({ esperaMs: null });
  });

  it("503 que se recupera en el segundo intento: sesión cargada", async () => {
    configurarPausasDeReintento([0, 0]);
    vi.mocked(apiFetch).mockImplementationOnce(() => r503("0")).mockImplementation(OK);
    await expect(consultarSesionConReintento()).resolves.toMatchObject({ acceso_permitido: true });
  });
});

// Pruebas originales de consultarSesion (deduplicación), conservadas.
describe("consultarSesion (deduplicación)", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("deduplica invocaciones concurrentes: dos llamadas producen una sola petición", async () => {
    // Simula el doble-mount de StrictMode: dos invocaciones en la misma pasada síncrona,
    // antes de que ninguna haya tenido chance de resolver.
    vi.mocked(apiFetch).mockResolvedValue(new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })));

    const [a, b] = await Promise.all([consultarSesion(), consultarSesion()]);

    expect(apiFetch).toHaveBeenCalledTimes(1);
    expect(a).toEqual(b);
    expect(a.acceso_permitido).toBe(true);
  });

  it("una vez resuelta, la siguiente invocación dispara una petición nueva (no cachea para siempre)", async () => {
    vi.mocked(apiFetch).mockImplementation(() =>
      Promise.resolve(new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))),
    );

    await consultarSesion();
    await consultarSesion();

    expect(apiFetch).toHaveBeenCalledTimes(2);
  });

  it("un error HTTP se propaga como excepción", async () => {
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
