import { describe, expect, it, vi } from "vitest";

import { ProtegidaPorModulo } from "./components/ProtegidaPorModulo";
import { InicioPage } from "./pages/InicioPage";
import { router } from "./router";

vi.mock("./lib/supabaseClient", () => ({ supabase: { auth: {} } }));

describe("router · inicio y acceso a Personas", () => {
  const ruta = (path: string) => router.routes.find((r) => r.path === path) as { element?: unknown } | undefined;

  it("/inicio existe y muestra InicioPage", () => {
    const elemento = ruta("/inicio")?.element as { type: unknown } | undefined;
    expect(elemento?.type).toBe(InicioPage);
  });

  it("/personas está protegida por puede_ver_modulo_1", () => {
    const elemento = ruta("/personas")?.element as { type: unknown; props: { campo: string } } | undefined;
    expect(elemento?.type).toBe(ProtegidaPorModulo);
    expect(elemento?.props.campo).toBe("puede_ver_modulo_1");
  });

  it("la raíz sigue siendo el login", () => {
    expect(ruta("/")).toBeDefined();
  });
});
