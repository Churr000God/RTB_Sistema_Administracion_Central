import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "./apiClient";
import { supabase } from "./supabaseClient";

vi.mock("./supabaseClient", () => ({
  supabase: {
    auth: {
      getSession: vi.fn().mockResolvedValue({
        data: { session: { access_token: "el-token" } },
      }),
    },
  },
}));

describe("apiFetch", () => {
  it("agrega el Authorization con el token de la sesión", async () => {
    globalThis.fetch = vi.fn().mockResolvedValue(new Response("{}"));

    await apiFetch("/api/personas");

    expect(fetch).toHaveBeenCalledWith(
      expect.stringContaining("/api/personas"),
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: "Bearer el-token" }),
      })
    );
  });
});
