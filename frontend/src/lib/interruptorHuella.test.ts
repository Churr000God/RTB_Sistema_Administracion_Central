import { describe, expect, it } from "vitest";

import { ErrorApi } from "./errorApi";
import {
  describirCambio,
  esEstadoInterruptor,
  esResultadoCambio,
  estadoDelError,
  fechaDeAtajo,
  fechaEnRango,
  notaValida,
  sanearNota,
  textoDeError,
} from "./interruptorHuella";
import { ESTADO_APAGADO, ESTADO_ENCENDIDO } from "../testing/interruptorHuella";

describe("esEstadoInterruptor", () => {
  it("acepta la forma del contrato", () => {
    expect(esEstadoInterruptor(ESTADO_APAGADO)).toBe(true);
    expect(esEstadoInterruptor(ESTADO_ENCENDIDO)).toBe(true);
  });

  it.each([
    [null],
    ["texto"],
    [{}],
    [{ ...ESTADO_APAGADO, estado: "raro" }],
    [{ ...ESTADO_APAGADO, activo: "si" }],
    [{ ...ESTADO_APAGADO, alarma: null }],
    [{ ...ESTADO_APAGADO, fecha_minima: undefined }],
  ])("rechaza una forma ilegible (%j): nunca se rellena con «apagado»", (datos) => {
    expect(esEstadoInterruptor(datos)).toBe(false);
  });
});

describe("esResultadoCambio", () => {
  it("exige resultado válido y un estado legible", () => {
    expect(esResultadoCambio({ resultado: "actualizada", estado: ESTADO_ENCENDIDO })).toBe(true);
    expect(esResultadoCambio({ resultado: "sin_cambio", estado: ESTADO_APAGADO })).toBe(true);
    expect(esResultadoCambio({ resultado: "otra", estado: ESTADO_APAGADO })).toBe(false);
    expect(esResultadoCambio({ resultado: "actualizada", estado: {} })).toBe(false);
    expect(esResultadoCambio(null)).toBe(false);
  });
});

describe("notas", () => {
  it("saneo: espacios colapsados y recortados; el mínimo se mide sobre lo saneado", () => {
    expect(sanearNota("  hola    mundo \n ok ")).toBe("hola mundo ok");
    expect(notaValida("123456789")).toBe(false);
    expect(notaValida("1234567890")).toBe(true);
    expect(notaValida("          abc")).toBe(false);
    expect(notaValida("a".repeat(500))).toBe(true);
    expect(notaValida("a".repeat(501))).toBe(false);
  });
});

describe("fechas", () => {
  it("fechaEnRango: dentro y fuera, y formato inválido", () => {
    expect(fechaEnRango("2026-10-10", "2026-10-10", "2026-11-09")).toBe(true);
    expect(fechaEnRango("2026-11-09", "2026-10-10", "2026-11-09")).toBe(true);
    expect(fechaEnRango("2026-11-10", "2026-10-10", "2026-11-09")).toBe(false);
    expect(fechaEnRango("2026-10-09", "2026-10-10", "2026-11-09")).toBe(false);
    expect(fechaEnRango("", "2026-10-10", "2026-11-09")).toBe(false);
    expect(fechaEnRango("10/10/2026", "2026-10-10", "2026-11-09")).toBe(false);
  });

  it("fechaDeAtajo: hoy + N, acotada al rango que manda el servidor", () => {
    expect(fechaDeAtajo(7, "2026-10-10", "2026-11-09", "2026-10-10")).toBe("2026-10-17");
    expect(fechaDeAtajo(14, "2026-10-10", "2026-11-09", "2026-10-10")).toBe("2026-10-24");
    expect(fechaDeAtajo(30, "2026-10-10", "2026-11-09", "2026-10-10")).toBe("2026-11-09");
    // el servidor puede cerrar el tope un día antes (margen de 60 s)
    expect(fechaDeAtajo(30, "2026-10-10", "2026-11-08", "2026-10-10")).toBe("2026-11-08");
    // si hoy ya no es elegible, el mínimo manda
    expect(fechaDeAtajo(0, "2026-10-11", "2026-11-09", "2026-10-10")).toBe("2026-10-11");
  });
});

describe("describirCambio", () => {
  it("interruptor: 0/1 se traducen y lo desconocido no se interpreta", () => {
    expect(describirCambio({ clave: "terminal_inferir_huella_activa", valor_anterior: "0", valor_nuevo: "1" })).toBe("Interruptor: Apagado → Encendido");
    expect(describirCambio({ clave: "terminal_inferir_huella_activa", valor_anterior: "1", valor_nuevo: "0" })).toBe("Interruptor: Encendido → Apagado");
    expect(describirCambio({ clave: "terminal_inferir_huella_activa", valor_anterior: "<b>x</b>", valor_nuevo: null })).toBe("Interruptor: — → —");
    expect(describirCambio({ clave: "otra_clave", valor_anterior: "1", valor_nuevo: "2" })).toBe("Otro ajuste");
  });

  it("vencimiento: instantes UTC a fecha de México; el centinela 1970 y lo ilegible son «—»", () => {
    expect(describirCambio({ clave: "terminal_inferir_huella_hasta", valor_anterior: "1970-01-01T00:00:00Z", valor_nuevo: "2026-10-25T05:59:59Z" })).toBe(
      "Vencimiento: — → 24 oct 2026",
    );
    expect(describirCambio({ clave: "terminal_inferir_huella_hasta", valor_anterior: "basura", valor_nuevo: null })).toBe("Vencimiento: — → —");
  });
});

describe("textoDeError / estadoDelError", () => {
  const err = (status: number, cuerpo: Record<string, unknown>) =>
    new ErrorApi(status, typeof cuerpo.detail === "string" ? cuerpo.detail : null, cuerpo);

  it.each([
    ["reintentar", "El cambio no se pudo aplicar por una operación concurrente; vuelve a intentarlo."],
    ["nota_repetida", "Escribe un motivo nuevo para la renovación."],
    ["nota_requerida", "La nota debe tener entre 10 y 500 caracteres."],
    ["hasta_invalido", "El vencimiento debe ser una fecha futura de a lo más 30 días."],
    ["sin_consentimiento_vigente", "Falta publicar el texto de consentimiento biométrico definitivo; mientras solo exista el provisional no se puede encender."],
    ["terminal_no_activa", "No hay ninguna terminal activa; no se puede encender."],
  ])("código %s -> texto fijo local, nunca el detail del servidor", (codigo, esperado) => {
    expect(textoDeError(err(409, { codigo, detail: "texto crudo <b>interno</b>" }))).toBe(esperado);
  });

  it("403 sin código, 503 y errores desconocidos", () => {
    expect(textoDeError(err(403, { detail: "interno" }))).toBe("No tienes permiso para cambiar el interruptor de la activación por huella.");
    expect(textoDeError(err(503, { detail: "interno" }))).toBe("Servicio no disponible; reintenta.");
    expect(textoDeError(err(500, { detail: "stack" }))).toBe("No se pudo completar. Inténtalo de nuevo.");
    expect(textoDeError(new Error("x"))).toBe("No se pudo completar. Inténtalo de nuevo.");
  });

  it("estadoDelError: sólo acepta un estado completo", () => {
    expect(estadoDelError(err(409, { codigo: "estado_desactualizado", estado: ESTADO_ENCENDIDO }))).toEqual(ESTADO_ENCENDIDO);
    expect(estadoDelError(err(409, { codigo: "estado_desactualizado", estado: { activo: true } }))).toBeNull();
    expect(estadoDelError(err(409, { codigo: "x" }))).toBeNull();
    expect(estadoDelError(new Error("x"))).toBeNull();
  });
});
