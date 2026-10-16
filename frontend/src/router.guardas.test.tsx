import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { createMemoryRouter, RouterProvider } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "./lib/apiClient";
import { supabase } from "./lib/supabaseClient";
import { router } from "./router";

vi.mock("./lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("./lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: { email: "mariana@example.com" } } }),
      getSession: vi.fn().mockResolvedValue({ data: { session: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const TODAS_EN_FALSE = {
  acceso_permitido: true,
  motivo_bloqueo: null,
  puede_ver_modulo_1: false,
  puede_ver_modulo_2: false,
  puede_ver_modulo_3: false,
  puede_ver_terminales: false,
};

function montar(ruta: string) {
  const enrutador = createMemoryRouter(router.routes, { initialEntries: [ruta] });
  return render(<RouterProvider router={enrutador} />);
}

function conSesion(banderas: Record<string, unknown>) {
  vi.mocked(apiFetch).mockImplementation((path: string) =>
    Promise.resolve(path === "/api/sesion" ? new Response(JSON.stringify({ ...TODAS_EN_FALSE, ...banderas })) : new Response(null, { status: 500 })),
  );
}

const pedidasAModulos = () => vi.mocked(apiFetch).mock.calls.map(([p]) => String(p)).filter((p) => p !== "/api/sesion");

// ruta de ejemplo de cada grupo -> bandera que la abre
// 4.º elemento: pantallas que NO piden datos al montar; se reconoce que se montó por su encabezado.
const GRUPOS: Array<[string, string, string, RegExp?]> = [
  ["Directorio de personas", "/personas", "puede_ver_modulo_1"],
  ["Alta de persona", "/personas/nueva", "puede_ver_modulo_1", /^alta de persona$/i],
  ["Alta de usuario", "/usuarios/nuevo", "puede_ver_modulo_1"],
  ["Cambio de estado", "/personas/abc/movimiento", "puede_ver_modulo_1"],
  ["Bitácora de movimientos", "/personas/abc/bitacora", "puede_ver_modulo_1"],
  ["Estructura organizacional", "/estructura/areas", "puede_ver_modulo_2"],
  ["Estructura (otra ruta del grupo)", "/estructura/permisos", "puede_ver_modulo_2"],
  ["Tiempo", "/tiempo/dias", "puede_ver_modulo_3"],
  ["Tiempo (parámetros)", "/tiempo/parametros/sistema", "puede_ver_modulo_3"],
  ["Terminales", "/tiempo/terminales", "puede_ver_terminales"],
  ["Terminales (configuración)", "/tiempo/terminales/configuracion/activacion-por-huella", "puede_ver_terminales"],
];

describe("router · guardas de pantalla (RutaVerificada)", () => {
  const originalLocation = window.location;
  let href = "";

  beforeEach(() => {
    href = "";
    vi.mocked(apiFetch).mockReset();
    vi.mocked(supabase.auth.signOut).mockClear();
    Object.defineProperty(window, "location", {
      configurable: true,
      value: {
        ...originalLocation,
        pathname: "/",
        get href() {
          return href;
        },
        set href(valor: string) {
          href = valor;
        },
      },
    });
  });

  afterEach(() => {
    Object.defineProperty(window, "location", { configurable: true, value: originalLocation });
  });

  describe.each(GRUPOS)("%s (%s)", (_nombre, ruta, bandera, encabezado) => {
    // «se montó la pantalla»: pidió datos o (si no pide ninguno al montar) muestra su encabezado.
    const seMontoLaPantalla = async () => {
      if (encabezado) await screen.findByRole("heading", { name: encabezado });
      else await waitFor(() => expect(pedidasAModulos().length).toBeGreaterThan(0));
    };

    it(`sin ${bandera} (aunque tenga las demás): «No tienes acceso a esta sección» con enlace a Inicio, y no se pide nada`, async () => {
      const otras = Object.fromEntries(Object.keys(TODAS_EN_FALSE).filter((k) => k.startsWith("puede_") && k !== bandera).map((k) => [k, true]));
      conSesion({ ...otras, [bandera]: false });
      montar(ruta);
      expect(await screen.findByText(/no tienes acceso a esta sección/i)).toBeInTheDocument();
      expect(screen.getByRole("link", { name: /ir a inicio/i })).toHaveAttribute("href", "/inicio");
      expect(pedidasAModulos()).toEqual([]);
    });

    it(`con ${bandera} en true: monta la pantalla (sí pide sus datos)`, async () => {
      conSesion({ [bandera]: true });
      montar(ruta);
      await seMontoLaPantalla();
      expect(screen.queryByText(/no tienes acceso a esta sección/i)).not.toBeInTheDocument();
    });

    it(`con la bandera ausente en la sesión cargada: bloquea (fail-closed)`, async () => {
      vi.mocked(apiFetch).mockImplementation((path: string) =>
        Promise.resolve(path === "/api/sesion" ? new Response(JSON.stringify({ acceso_permitido: true })) : new Response(null, { status: 500 })),
      );
      montar(ruta);
      expect(await screen.findByText(/no tienes acceso a esta sección/i)).toBeInTheDocument();
      expect(pedidasAModulos()).toEqual([]);
    });

    it("error de sesión (500): «No pudimos verificar tu acceso» con Reintentar, nada se monta ni se pide", async () => {
      vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(null, { status: 500 })));
      montar(ruta);
      expect(await screen.findByText("No pudimos verificar tu acceso")).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "Reintentar" })).toBeInTheDocument();
      expect(screen.queryByText(/no tienes acceso a esta sección/i)).not.toBeInTheDocument();
      expect(pedidasAModulos()).toEqual([]);
    });

    it("tras un error, Reintentar con respuesta y bandera monta la pantalla", async () => {
      vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(null, { status: 503 })));
      montar(ruta);
      await screen.findByText("No pudimos verificar tu acceso");
      conSesion({ [bandera]: true });
      await userEvent.click(screen.getAllByRole("button", { name: "Reintentar" })[0]);
      await seMontoLaPantalla();
    });

    it("401: cierra la sesión (best-effort) y manda al login sin pedir nada", async () => {
      vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(null, { status: 401 })));
      montar(ruta);
      await waitFor(() => expect(href).toBe("/"));
      expect(supabase.auth.signOut).toHaveBeenCalledTimes(1);
      expect(pedidasAModulos()).toEqual([]);
    });
  });

  it("la excepción de Terminales: modulo_3 en true NO abre /tiempo/terminales, ni terminales abre /tiempo/dias", async () => {
    conSesion({ puede_ver_modulo_3: true, puede_ver_terminales: false });
    const a = montar("/tiempo/terminales");
    expect(await screen.findByText(/no tienes acceso a esta sección/i)).toBeInTheDocument();
    a.unmount();
    vi.mocked(apiFetch).mockReset();
    conSesion({ puede_ver_modulo_3: false, puede_ver_terminales: true });
    montar("/tiempo/dias");
    expect(await screen.findByText(/no tienes acceso a esta sección/i)).toBeInTheDocument();
    expect(pedidasAModulos()).toEqual([]);
  });

  it("401 con signOut que falla o se cuelga: igual redirige al login", async () => {
    vi.mocked(supabase.auth.signOut).mockRejectedValueOnce(new Error("sin red"));
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(null, { status: 401 })));
    const a = montar("/estructura/areas");
    await waitFor(() => expect(href).toBe("/"));
    a.unmount();
    href = "";
    vi.mocked(supabase.auth.signOut).mockImplementationOnce(() => new Promise(() => {}) as never);
    montar("/estructura/areas");
    await waitFor(() => expect(href).toBe("/"), { timeout: 4000 });
  });

  // Último a propósito: deja /api/sesion colgado y la consulta se deduplica a nivel de módulo.
  it("cargando: «Verificando acceso…» y no se monta ni se pide nada", async () => {
    vi.mocked(apiFetch).mockImplementation(() => new Promise<Response>(() => {}));
    montar("/estructura/areas");
    expect(await screen.findByText("Verificando acceso…")).toBeInTheDocument();
    expect(pedidasAModulos()).toEqual([]);
  });
});

describe("router · rutas de personas SIN guarda de módulo (a propósito)", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it.each([["/personas/abc"], ["/personas/abc/bitacora-asignaciones"]])(
    "%s se monta aunque la sesión no traiga ninguna bandera de módulo (la autoridad es backend/RLS)",
    async (ruta) => {
      conSesion({});
      montar(ruta);
      await waitFor(() => expect(pedidasAModulos().length).toBeGreaterThan(0));
      expect(screen.queryByText(/no tienes acceso a esta sección/i)).not.toBeInTheDocument();
    },
  );
});
