import { describe, expect, it } from "vitest";

import { ErrorApi } from "./errorApi";
import {
  ETIQUETA_CONTACTO,
  esConflictoDeConsentimiento,
  esConsentimientoCompleto,
  ETIQUETA_ESTADO_ALTA,
  cuentaRegresiva,
  descripcionUltimoContacto,
  formatearDesfase,
} from "./terminales";

const AHORA = new Date("2026-10-08T12:00:00Z");

describe("cuentaRegresiva", () => {
  it("más de una hora: horas y minutos, sin urgencia", () => {
    expect(cuentaRegresiva("2026-10-09T07:40:00Z", AHORA)).toEqual({
      texto: "Caduca en 19 h 40 min",
      urgente: false,
      vencida: false,
    });
  });

  it("una hora o menos: urgente y avisa que se dará de baja sola", () => {
    expect(cuentaRegresiva("2026-10-08T13:00:00Z", AHORA)).toMatchObject({
      texto: "Caduca en 1 h 00 min · se dará de baja sola",
      urgente: true,
      vencida: false,
    });
    expect(cuentaRegresiva("2026-10-08T12:25:00Z", AHORA)?.texto).toBe("Caduca en 25 min · se dará de baja sola");
  });

  it("ya vencida: lo dice sin números negativos (la baja ocurre en la siguiente corrida)", () => {
    expect(cuentaRegresiva("2026-10-08T11:00:00Z", AHORA)).toEqual({
      texto: "Venció; se dará de baja en la siguiente corrida",
      urgente: true,
      vencida: true,
    });
  });

  it("redondea hacia arriba los segundos sueltos y vence exactamente en cero", () => {
    expect(cuentaRegresiva("2026-10-08T12:00:30Z", AHORA)?.texto).toBe("Caduca en 1 min · se dará de baja sola");
    expect(cuentaRegresiva("2026-10-08T12:00:00Z", AHORA)?.vencida).toBe(true);
  });

  it("fecha inválida: no inventa una cuenta", () => {
    expect(cuentaRegresiva("no-es-fecha", AHORA)).toBeNull();
  });
});

describe("cuentaRegresiva: bordes", () => {
  it("la urgencia empieza exactamente a los 60 min: 61 min no es urgente, 60 sí", () => {
    expect(cuentaRegresiva("2026-10-08T13:01:00Z", AHORA)?.urgente).toBe(false);
    expect(cuentaRegresiva("2026-10-08T13:00:00Z", AHORA)?.urgente).toBe(true);
  });

  it("redondea hacia arriba (no hacia abajo ni al más cercano)", () => {
    // faltan 19 h 39 min 40 s -> «19 h 40 min» (round también daría 40; floor daría 39)
    expect(cuentaRegresiva("2026-10-09T07:39:40Z", AHORA)?.texto).toBe("Caduca en 19 h 40 min");
    // faltan 59 s -> «1 min» (round daría 1, floor 0)
    expect(cuentaRegresiva("2026-10-08T12:00:59Z", AHORA)?.texto).toBe("Caduca en 1 min · se dará de baja sola");
    // faltan 20 s -> «1 min» (round daría 0)
    expect(cuentaRegresiva("2026-10-08T12:00:20Z", AHORA)?.texto).toBe("Caduca en 1 min · se dará de baja sola");
  });
});

describe("descripcionUltimoContacto: bordes", () => {
  it.each([
    [59, "hace 59 s"],
    [60, "hace 1 min"],
    [3599, "hace 59 min"],
    [3600, "hace 1 h"],
    [86399, "hace 23 h"],
    [86400, "hace 1 día"],
    [172800, "hace 2 días"],
  ])("%i s → %s", (segundos, texto) => {
    expect(descripcionUltimoContacto(segundos)).toBe(texto);
  });
});

describe("descripcionUltimoContacto", () => {
  it.each([
    [40, "hace 40 s"],
    [180, "hace 3 min"],
    [3 * 3600 + 120, "hace 3 h"],
    [2 * 86400 + 5, "hace 2 días"],
  ])("%i s → %s", (segundos, texto) => {
    expect(descripcionUltimoContacto(segundos)).toBe(texto);
  });

  it("null (nunca se comunicó) → —", () => {
    expect(descripcionUltimoContacto(null)).toBe("—");
  });
});

describe("formatearDesfase", () => {
  it.each([
    [2, "+2 s"],
    [-95, "-95 s"],
    [0, "0 s"],
    [null, "—"],
  ])("%s → %s", (valor, texto) => {
    expect(formatearDesfase(valor)).toBe(texto);
  });
});

describe("etiquetas", () => {
  it("cubren los 5 estados de alta y los 4 niveles de contacto", () => {
    expect(Object.keys(ETIQUETA_ESTADO_ALTA)).toHaveLength(5);
    expect(ETIQUETA_ESTADO_ALTA.esperando_huella).toBe("Esperando huella");
    expect(ETIQUETA_CONTACTO.nunca).toBe("Sin conexión todavía");
    expect(ETIQUETA_CONTACTO.sin_contacto).toBe("Sin contacto");
  });
});

describe("esConsentimientoCompleto (el cuerpo de un 409 no es de fiar: forma completa o nada)", () => {
  const OK = { id: 4, version: 4, texto: "Texto", provisional: false, cambio_material: false, vigente_desde: "2026-10-08T00:00:00Z" };

  it("acepta un objeto con id y version numéricos y texto no vacío", () => {
    expect(esConsentimientoCompleto(OK)).toBe(true);
  });

  it.each([
    ["null", null],
    ["no es objeto", "x"],
    ["sin id", { ...OK, id: undefined }],
    ["id como texto", { ...OK, id: "4" }],
    ["sin version", { ...OK, version: undefined }],
    ["version NaN", { ...OK, version: Number.NaN }],
    ["texto vacío", { ...OK, texto: "" }],
    ["texto null", { ...OK, texto: null }],
    ["texto número", { ...OK, texto: 5 }],
  ])("rechaza %s", (_nombre, valor) => {
    expect(esConsentimientoCompleto(valor)).toBe(false);
  });
});

describe("esConflictoDeConsentimiento (prioriza el código estable del backend)", () => {
  it.each(["consentimiento_desactualizado", "version_base_desactualizada"])("código %s es conflicto aunque el detail no lo diga", (codigo) => {
    expect(esConflictoDeConsentimiento(new ErrorApi(409, "Mensaje cualquiera.", { codigo }))).toBe(true);
  });

  it("un código de otro conflicto NO lo es, aunque el detail mencione el consentimiento", () => {
    expect(esConflictoDeConsentimiento(new ErrorApi(409, "El consentimiento de la alta ya existe.", { codigo: "alta_duplicada" }))).toBe(false);
  });

  it("sin código (backend anterior) cae a reconocer el texto del detail", () => {
    expect(esConflictoDeConsentimiento(new ErrorApi(409, "El texto de consentimiento cambió; vuelve a leerlo.", null))).toBe(true);
    expect(esConflictoDeConsentimiento(new ErrorApi(409, "La persona ya tiene un alta vigente en esta terminal.", null))).toBe(false);
  });

  it("sin detail ni código no es conflicto", () => {
    expect(esConflictoDeConsentimiento(new ErrorApi(409, null, null))).toBe(false);
  });
});
