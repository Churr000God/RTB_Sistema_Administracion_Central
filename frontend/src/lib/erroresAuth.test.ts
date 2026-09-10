import { afterEach, describe, expect, it, vi } from "vitest";

import { esInsuficienteAal, mensajeDeErrorAuth, registrarErrorAuth } from "./erroresAuth";

describe("mensajeDeErrorAuth", () => {
  it("mapea insufficient_aal al mensaje que dispara el paso TOTP", () => {
    expect(mensajeDeErrorAuth({ code: "insufficient_aal" }, "por defecto")).toMatch(
      /confirmá el código de tu app autenticadora/i
    );
  });

  it("mapea same_password", () => {
    expect(mensajeDeErrorAuth({ code: "same_password" }, "por defecto")).toMatch(
      /distinta de la actual/i
    );
  });

  it("mapea weak_password, otp_expired y over_request_rate_limit", () => {
    expect(mensajeDeErrorAuth({ code: "weak_password" }, "x")).toMatch(/débil/i);
    expect(mensajeDeErrorAuth({ code: "otp_expired" }, "x")).toMatch(/venció/i);
    expect(mensajeDeErrorAuth({ code: "over_request_rate_limit" }, "x")).toMatch(
      /demasiados intentos/i
    );
  });

  it("cae al mensaje por defecto cuando el código no está en el diccionario cerrado", () => {
    expect(mensajeDeErrorAuth({ code: "algo_no_mapeado" }, "mensaje genérico")).toBe(
      "mensaje genérico"
    );
  });

  it("usa el status 429 como pista cuando no hay code", () => {
    expect(mensajeDeErrorAuth({ status: 429 }, "genérico")).toMatch(/demasiados intentos/i);
  });

  it("un error sin code ni status conocido no rompe: cae al mensaje por defecto", () => {
    expect(mensajeDeErrorAuth({}, "genérico")).toBe("genérico");
    expect(mensajeDeErrorAuth(null, "genérico")).toBe("genérico");
    expect(mensajeDeErrorAuth(undefined, "genérico")).toBe("genérico");
  });

  it("nunca devuelve error.message crudo, aunque el error lo traiga", () => {
    const resultado = mensajeDeErrorAuth(
      { code: "no_mapeado", message: "detalle interno de auth-js" },
      "genérico"
    );
    expect(resultado).not.toContain("detalle interno de auth-js");
  });
});

describe("esInsuficienteAal", () => {
  it("distingue el código insufficient_aal de otros", () => {
    expect(esInsuficienteAal({ code: "insufficient_aal" })).toBe(true);
    expect(esInsuficienteAal({ code: "same_password" })).toBe(false);
    expect(esInsuficienteAal(null)).toBe(false);
    expect(esInsuficienteAal(undefined)).toBe(false);
  });
});

describe("registrarErrorAuth", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("loguea name/code/status/message sin lanzar, incluso con un error vacío", () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});

    registrarErrorAuth("contexto-test", {
      name: "AuthApiError",
      code: "insufficient_aal",
      status: 401,
      message: "detalle interno",
    });
    expect(spy).toHaveBeenCalledWith(
      "contexto-test",
      expect.objectContaining({ code: "insufficient_aal", status: 401 })
    );

    expect(() => registrarErrorAuth("contexto-vacio", null)).not.toThrow();
    expect(() => registrarErrorAuth("contexto-undefined", undefined)).not.toThrow();
  });
});
