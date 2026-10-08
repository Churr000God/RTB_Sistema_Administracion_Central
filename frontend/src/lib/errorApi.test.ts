import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "./apiClient";
import { ErrorApi, apiJson, codigoDe, leerErrorApi, mensajeDeNegocio } from "./errorApi";

vi.mock("./apiClient", () => ({ apiFetch: vi.fn() }));

function respuesta(status: number, cuerpo: unknown) {
  return new Response(typeof cuerpo === "string" ? cuerpo : JSON.stringify(cuerpo), { status });
}

describe("leerErrorApi", () => {
  it("conserva status, detail y los campos hermanos del cuerpo (409 de consentimiento)", async () => {
    const vigente = { id: 4, version: 4, texto: "Texto", provisional: false };
    const error = await leerErrorApi(
      respuesta(409, { detail: "El texto de consentimiento cambió; vuelve a leerlo.", consentimiento_vigente: vigente }),
    );
    expect(error).toBeInstanceOf(ErrorApi);
    expect(error.status).toBe(409);
    expect(error.detail).toBe("El texto de consentimiento cambió; vuelve a leerlo.");
    expect(error.cuerpo?.consentimiento_vigente).toEqual(vigente);
  });

  it("conserva no_elegibles (409 de lote) y valor_actual (409 de variables)", async () => {
    const lote = await leerErrorApi(
      respuesta(409, { detail: "No se registró nada", no_elegibles: [{ tu_id: 81, razon: "en_baja" }] }),
    );
    expect(lote.cuerpo?.no_elegibles).toEqual([{ tu_id: 81, razon: "en_baja" }]);
    const variable = await leerErrorApi(respuesta(409, { detail: "Cambió", valor_actual: 36 }));
    expect(variable.cuerpo?.valor_actual).toBe(36);
  });

  it("422 de Pydantic (detail es una lista): detail es null y el cuerpo se conserva", async () => {
    const error = await leerErrorApi(respuesta(422, { detail: [{ loc: ["body", "motivo"], msg: "x" }] }));
    expect(error.status).toBe(422);
    expect(error.detail).toBeNull();
    expect(Array.isArray(error.cuerpo?.detail)).toBe(true);
  });

  it("503 o cuerpo no JSON: detail null, cuerpo null, status intacto", async () => {
    const error = await leerErrorApi(respuesta(503, "<html>boom</html>"));
    expect(error.status).toBe(503);
    expect(error.detail).toBeNull();
    expect(error.cuerpo).toBeNull();
  });

  it("un cuerpo JSON que no es objeto (p. ej. una lista) no rompe", async () => {
    const error = await leerErrorApi(respuesta(500, [1, 2]));
    expect(error.cuerpo).toBeNull();
  });
});

describe("apiJson", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("devuelve el JSON de una respuesta correcta", async () => {
    vi.mocked(apiFetch).mockResolvedValue(respuesta(200, { total: 1 }));
    await expect(apiJson<{ total: number }>("/api/x")).resolves.toEqual({ total: 1 });
    expect(apiFetch).toHaveBeenCalledWith("/api/x", undefined);
  });

  it("lanza ErrorApi con el cuerpo completo ante 4xx/5xx", async () => {
    vi.mocked(apiFetch).mockResolvedValue(respuesta(409, { detail: "d", valor_actual: 9 }));
    const error = (await apiJson("/api/x").catch((e) => e)) as ErrorApi;
    expect(error).toBeInstanceOf(ErrorApi);
    expect(error.status).toBe(409);
    expect(error.cuerpo?.valor_actual).toBe(9);
  });

  it("una falla de red se vuelve ErrorApi con status 0 (la UI la trata como error genérico)", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.reject(new TypeError("Failed to fetch")));
    let error: unknown;
    try {
      await apiJson("/api/x");
    } catch (e) {
      error = e;
    }
    expect(error).toBeInstanceOf(ErrorApi);
    expect((error as ErrorApi).status).toBe(0);
    expect((error as ErrorApi).detail).toBeNull();
  });

  it("un 200 con cuerpo no JSON lanza ErrorApi 503-like (forma inesperada), no un SyntaxError", async () => {
    vi.mocked(apiFetch).mockResolvedValue(new Response("ok pero no json", { status: 200 }));
    const error = (await apiJson("/api/x").catch((e) => e)) as ErrorApi;
    expect(error).toBeInstanceOf(ErrorApi);
    expect(error.status).toBe(200);
  });
});

describe("mensajeDeNegocio", () => {
  const GENERICO = "No se pudo completar.";

  it.each([403, 409, 422])("%i con detail de texto: se muestra tal cual (mensaje fijo del backend)", (status) => {
    expect(mensajeDeNegocio(new ErrorApi(status, "Mensaje fijo.", null), GENERICO)).toBe("Mensaje fijo.");
  });

  it("503 usa su mensaje propio, aunque traiga detail", () => {
    expect(mensajeDeNegocio(new ErrorApi(503, "interno", null), GENERICO)).toBe("Servicio no disponible; reintenta.");
  });

  it.each([400, 404, 500])("%i con detail interno nunca se muestra: cae al genérico", (status) => {
    expect(mensajeDeNegocio(new ErrorApi(status, "psycopg2 tiempo.x", null), GENERICO)).toBe(GENERICO);
  });

  it("403/409/422 sin detail legible (p. ej. el 422 de Pydantic) cae al genérico", () => {
    expect(mensajeDeNegocio(new ErrorApi(422, null, { detail: [{ msg: "x" }] }), GENERICO)).toBe(GENERICO);
  });

  it("un error que no es ErrorApi (bug propio) cae al genérico", () => {
    expect(mensajeDeNegocio(new TypeError("x"), GENERICO)).toBe(GENERICO);
  });
});

describe("codigoDe", () => {
  it("devuelve el código estable del cuerpo si es texto", () => {
    expect(codigoDe(new ErrorApi(409, "x", { codigo: "valor_desactualizado" }))).toBe("valor_desactualizado");
  });

  it.each([[null], [{}], [{ codigo: 5 }], [{ codigo: "" }]])("sin código válido (%j) es null", (cuerpo) => {
    expect(codigoDe(new ErrorApi(409, "x", cuerpo as Record<string, unknown> | null))).toBeNull();
  });

  it("un error que no es de la API no tiene código", () => {
    expect(codigoDe(new TypeError("x"))).toBeNull();
  });
});
