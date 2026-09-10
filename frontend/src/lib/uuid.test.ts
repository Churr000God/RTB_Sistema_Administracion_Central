import { afterEach, describe, expect, it, vi } from "vitest";

import { generarUuidV4 } from "./uuid";

const UUID_V4_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

describe("generarUuidV4", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("usa crypto.randomUUID cuando está disponible", () => {
    const espia = vi.spyOn(crypto, "randomUUID").mockReturnValue("11111111-1111-4111-8111-111111111111");
    expect(generarUuidV4()).toBe("11111111-1111-4111-8111-111111111111");
    expect(espia).toHaveBeenCalledOnce();
  });

  it("cae a crypto.getRandomValues cuando randomUUID no existe (contexto inseguro: HTTP sin TLS)", () => {
    const original = crypto.randomUUID;
    // @ts-expect-error — simula el navegador en contexto inseguro, donde randomUUID es undefined
    delete crypto.randomUUID;
    try {
      const id = generarUuidV4();
      expect(id).toMatch(UUID_V4_REGEX);
    } finally {
      crypto.randomUUID = original;
    }
  });
});
