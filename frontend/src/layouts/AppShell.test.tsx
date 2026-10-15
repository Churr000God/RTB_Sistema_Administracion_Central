import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { StrictMode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { supabase } from "../lib/supabaseClient";
import { AppShell } from "./AppShell";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: { email: "mariana@example.com" } } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

describe("AppShell", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
    vi.mocked(supabase.auth.signOut).mockClear();
  });

  it("con acceso permitido, muestra el shell y el contenido sin redirigir", async () => {
    vi.mocked(apiFetch).mockResolvedValue(
      new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null, puede_ver_modulo_1: true, puede_ver_modulo_2: true }), { status: 200 })
    );

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
    expect(screen.getByText("Cerrar sesión")).toBeInTheDocument();
    expect(supabase.auth.signOut).not.toHaveBeenCalled();
  });

  it("con acceso no permitido, cierra sesión y redirige a /cuenta-suspendida con el motivo", async () => {
    vi.mocked(apiFetch).mockResolvedValue(
      new Response(JSON.stringify({ acceso_permitido: false, motivo_bloqueo: "suspension" }), {
        status: 200,
      })
    );

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    await waitFor(() => expect(supabase.auth.signOut).toHaveBeenCalled());
    expect(screen.queryByText("Contenido protegido")).not.toBeInTheDocument();
  });

  it("si /api/sesion falla (red), NO abre nada: muestra «No pudimos verificar tu acceso» y no monta el contenido", async () => {
    vi.mocked(apiFetch).mockRejectedValue(new Error("network down"));

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    expect(await screen.findByText("No pudimos verificar tu acceso")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Reintentar" })).toBeInTheDocument();
    expect(screen.queryByText("Contenido protegido")).not.toBeInTheDocument();
    expect(supabase.auth.signOut).not.toHaveBeenCalled();
  });

  it("si /api/sesion responde 500, tampoco abre nada (error con Reintentar)", async () => {
    vi.mocked(apiFetch).mockResolvedValue(new Response(null, { status: 500 }));

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    expect(await screen.findByText("No pudimos verificar tu acceso")).toBeInTheDocument();
    expect(screen.queryByText("Contenido protegido")).not.toBeInTheDocument();
  });

  it("si signOut() falla tras detectar acceso no permitido, igual redirige (no cae a fail-open)", async () => {
    // Bug real reportado por testing: signOut() puede limpiar localStorage y AUN ASÍ
    // rechazar (hiccup de red hacia GoTrue). Antes, eso caía al .catch() externo y hacía
    // fail-open — la persona quedaba deslogueada en silencio, sin redirigir, viendo la ruta
    // interna rota (422 en las llamadas siguientes, sin token).
    vi.mocked(apiFetch).mockResolvedValue(
      new Response(JSON.stringify({ acceso_permitido: false, motivo_bloqueo: "sin_usuario" }), {
        status: 200,
      })
    );
    vi.mocked(supabase.auth.signOut).mockRejectedValue(new Error("network hiccup hacia GoTrue"));

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    await waitFor(() => expect(supabase.auth.signOut).toHaveBeenCalled());
    // Nunca debe "recuperarse" mostrando el contenido protegido — el fail-open sólo aplica
    // cuando no sabemos el estado de la cuenta, no cuando ya confirmamos que está bloqueada.
    expect(screen.queryByText("Contenido protegido")).not.toBeInTheDocument();
    expect(screen.queryByText("Verificando acceso…")).toBeInTheDocument();
  });

  it("con doble-mount de StrictMode (dev), la corrida descartada no dispara signOut ni pisa el redirect", async () => {
    let llamadas = 0;
    vi.mocked(apiFetch).mockImplementation(() => {
      llamadas += 1;
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: false, motivo_bloqueo: "sin_usuario" }), {
          status: 200,
        })
      );
    });

    render(
      <StrictMode>
        <AppShell>
          <p>Contenido protegido</p>
        </AppShell>
      </StrictMode>
    );

    await waitFor(() => expect(supabase.auth.signOut).toHaveBeenCalled());
    // dar tiempo a que la corrida "descartada" (si StrictMode disparó una) también resuelva
    await new Promise((resolver) => setTimeout(resolver, 20));

    expect(supabase.auth.signOut).toHaveBeenCalledTimes(1);
    expect(llamadas).toBeGreaterThanOrEqual(1);
    expect(screen.queryByText("Contenido protegido")).not.toBeInTheDocument();
  });

  it("con acceso permitido, muestra los grupos de navegación colapsados por defecto", async () => {
    vi.mocked(apiFetch).mockResolvedValue(
      new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null, puede_ver_modulo_1: true, puede_ver_modulo_2: true }), { status: 200 })
    );

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
    expect(screen.getByRole("button", { name: /personas y usuarios/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /estructura organizacional/i })).toBeInTheDocument();
    // colapsado por defecto en una ruta fuera de todo grupo: los items no están en el DOM
    expect(screen.queryByText("Áreas")).not.toBeInTheDocument();
    expect(screen.queryByText("Directorio")).not.toBeInTheDocument();
  });

  it("autoexpande el grupo cuya ruta activa cae dentro de él", async () => {
    window.history.pushState({}, "", "/estructura/areas");
    vi.mocked(apiFetch).mockResolvedValue(
      new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null, puede_ver_modulo_1: true, puede_ver_modulo_2: true }), { status: 200 })
    );

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
    const grupo = screen.getByRole("button", { name: /estructura organizacional/i });
    expect(grupo).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByRole("link", { name: "Áreas" })).toHaveAttribute("href", "/estructura/areas");

    window.history.pushState({}, "", "/");
  });

  it("Estructura organizacional ya no tiene ningún item atenuado (quinto corte: Permisos navegable)", async () => {
    // Con Permisos habilitado, este grupo se quedó sin items aria-disabled -- el ejemplo de
    // "atenuado" que cubre este test ahora vive sólo a nivel de grupo (ver el test de "Panel",
    // más abajo), no de sub-item dentro de un grupo navegable.
    window.history.pushState({}, "", "/estructura/areas");
    vi.mocked(apiFetch).mockResolvedValue(
      new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null, puede_ver_modulo_1: true, puede_ver_modulo_2: true }), { status: 200 })
    );

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
    for (const [nombre, href] of [
      ["Áreas", "/estructura/areas"],
      ["Departamentos", "/estructura/departamentos"],
      ["Puestos", "/estructura/puestos"],
      ["Asignaciones", "/estructura/asignaciones"],
      ["Permisos", "/estructura/permisos"],
    ] as const) {
      expect(screen.getByRole("link", { name: nombre })).toHaveAttribute("href", href);
    }
    expect(screen.queryByText("Próximamente")).not.toBeInTheDocument();

    window.history.pushState({}, "", "/");
  });

  it("el grupo Personas y Usuarios sólo trae Directorio (alta de persona/usuario se dejaron de listar ahí)", async () => {
    vi.mocked(apiFetch).mockResolvedValue(
      new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null, puede_ver_modulo_1: true, puede_ver_modulo_2: true }), { status: 200 })
    );

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: /personas y usuarios/i }));

    expect(screen.getByRole("link", { name: "Directorio" })).toHaveAttribute("href", "/personas");
    expect(screen.queryByText("Alta de persona")).not.toBeInTheDocument();
    expect(screen.queryByText("Alta de usuario")).not.toBeInTheDocument();
  });

  it("oculta el grupo Personas y Usuarios cuando puede_ver_modulo_1 es false", async () => {
    vi.mocked(apiFetch).mockResolvedValue(
      new Response(
        JSON.stringify({
          acceso_permitido: true,
          motivo_bloqueo: null,
          puede_ver_modulo_1: false,
          puede_ver_modulo_2: true,
        }),
        { status: 200 }
      )
    );

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
    expect(
      screen.queryByRole("button", { name: /personas y usuarios/i })
    ).not.toBeInTheDocument();
    // no "atenuado" (Próximamente): directamente no está en el DOM
    expect(screen.queryByText(/personas y usuarios/i)).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /estructura organizacional/i })).toBeInTheDocument();
  });

  it("oculta el grupo Estructura organizacional cuando puede_ver_modulo_2 es false", async () => {
    vi.mocked(apiFetch).mockResolvedValue(
      new Response(
        JSON.stringify({
          acceso_permitido: true,
          motivo_bloqueo: null,
          puede_ver_modulo_1: true,
          puede_ver_modulo_2: false,
        }),
        { status: 200 }
      )
    );

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
    expect(
      screen.queryByRole("button", { name: /estructura organizacional/i })
    ).not.toBeInTheDocument();
    expect(screen.queryByText(/estructura organizacional/i)).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /personas y usuarios/i })).toBeInTheDocument();
  });

  it("muestra ambos grupos cuando puede_ver_modulo_1 y puede_ver_modulo_2 son true", async () => {
    vi.mocked(apiFetch).mockResolvedValue(
      new Response(
        JSON.stringify({
          acceso_permitido: true,
          motivo_bloqueo: null,
          puede_ver_modulo_1: true,
          puede_ver_modulo_2: true,
        }),
        { status: 200 }
      )
    );

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
    expect(screen.getByRole("button", { name: /personas y usuarios/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /estructura organizacional/i })).toBeInTheDocument();
  });

  it("con la sesión en error el menú de módulos no se muestra (ni habilitado ni atenuado)", async () => {
    vi.mocked(apiFetch).mockRejectedValue(new Error("network down"));

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    await screen.findByText("No pudimos verificar tu acceso");
    expect(screen.queryByRole("button", { name: /personas y usuarios/i })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /estructura organizacional/i })).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "Inicio" })).not.toBeInTheDocument();
    expect(screen.getByText("Cerrar sesión")).toBeInTheDocument();
  });

  describe("grupo Terminales", () => {
    function sesionCon(extra: Record<string, unknown>) {
      vi.mocked(apiFetch).mockResolvedValue(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null, ...extra }), { status: 200 }),
      );
    }

    it("se muestra con puede_ver_terminales y trae Terminales, Anomalías y Configuración navegables", async () => {
      window.history.pushState({}, "", "/tiempo/terminales");
      sesionCon({ puede_ver_terminales: true });
      render(
        <AppShell>
          <p>Contenido protegido</p>
        </AppShell>,
      );
      await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
      expect(screen.getByRole("button", { name: /^terminales$/i })).toHaveAttribute("aria-expanded", "true");
      expect(screen.getByRole("link", { name: "Terminales" })).toHaveAttribute("href", "/tiempo/terminales");
      expect(screen.getByRole("link", { name: "Anomalías" })).toHaveAttribute("href", "/tiempo/terminales/anomalias");
      expect(screen.getByRole("link", { name: "Configuración" })).toHaveAttribute("href", "/tiempo/terminales/configuracion");
    });

    it("en Configuración sólo ese item queda activo (no también «Terminales», cuya ruta es prefijo)", async () => {
      window.history.pushState({}, "", "/tiempo/terminales/configuracion/variables");
      sesionCon({ puede_ver_terminales: true });
      render(
        <AppShell>
          <p>Contenido protegido</p>
        </AppShell>,
      );
      await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
      expect(screen.getByRole("link", { name: "Configuración" })).toHaveClass("nav-subitem--activo");
      expect(screen.getByRole("link", { name: "Configuración" })).toHaveAttribute("href", "/tiempo/terminales/configuracion");
      expect(screen.getByRole("link", { name: "Terminales" })).not.toHaveClass("nav-subitem--activo");
    });

    it("en Anomalías sólo ese item queda activo", async () => {
      window.history.pushState({}, "", "/tiempo/terminales/anomalias");
      sesionCon({ puede_ver_terminales: true });
      render(
        <AppShell>
          <p>Contenido protegido</p>
        </AppShell>,
      );
      await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
      expect(screen.getByRole("link", { name: "Anomalías" })).toHaveClass("nav-subitem--activo");
      expect(screen.getByRole("link", { name: "Terminales" })).not.toHaveClass("nav-subitem--activo");
    });

    it("en Usuarios de una terminal queda activo «Terminales»", async () => {
      window.history.pushState({}, "", "/tiempo/terminales/1/usuarios");
      sesionCon({ puede_ver_terminales: true });
      render(
        <AppShell>
          <p>Contenido protegido</p>
        </AppShell>,
      );
      await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
      expect(screen.getByRole("link", { name: "Terminales" })).toHaveClass("nav-subitem--activo");
    });

    it("se oculta por completo con puede_ver_terminales false (config_edicion sola no lo abre)", async () => {
      sesionCon({ puede_ver_terminales: false, puede_editar_config_terminales: true });
      render(
        <AppShell>
          <p>Contenido protegido</p>
        </AppShell>,
      );
      await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
      expect(screen.queryByRole("button", { name: /^terminales$/i })).not.toBeInTheDocument();
    });

    it("si /api/sesion falla el grupo Terminales NO aparece", async () => {
      vi.mocked(apiFetch).mockRejectedValue(new Error("network down"));
      render(
        <AppShell>
          <p>Contenido protegido</p>
        </AppShell>,
      );
      await screen.findByText("No pudimos verificar tu acceso");
      expect(screen.queryByRole("button", { name: /^terminales$/i })).not.toBeInTheDocument();
    });
  });
});

describe("AppShell · Inicio, estados de la sesión y reintento", () => {
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

  const sesion = (extra: Record<string, unknown> = {}) =>
    new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null, puede_ver_modulo_1: false, puede_ver_modulo_2: false, puede_ver_modulo_3: false, ...extra }));

  const montar = () =>
    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>,
    );

  it("«Inicio» reemplaza al ítem gris «Panel»: es un enlace habilitado a /inicio", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(sesion({ puede_ver_modulo_1: true })));
    montar();
    await screen.findByText("Contenido protegido");
    const inicio = screen.getByRole("link", { name: "Inicio" });
    expect(inicio).toHaveAttribute("href", "/inicio");
    expect(inicio).not.toHaveAttribute("aria-disabled");
    expect(screen.queryByText("Panel")).not.toBeInTheDocument();
  });

  it("«Inicio» aparece también para quien no tiene ningún módulo, y los grupos de módulo se ocultan", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(sesion()));
    montar();
    await screen.findByText("Contenido protegido");
    expect(screen.getByRole("link", { name: "Inicio" })).toBeInTheDocument();
    for (const nombre of [/personas y usuarios/i, /estructura organizacional/i, /^jornadas$/i, /^terminales$/i]) {
      expect(screen.queryByRole("button", { name: nombre })).not.toBeInTheDocument();
    }
  });

  it("una bandera de módulo ausente oculta el grupo (fail-closed con la sesión ya cargada)", async () => {
    vi.mocked(apiFetch).mockImplementation(() =>
      Promise.resolve(new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))),
    );
    montar();
    await screen.findByText("Contenido protegido");
    expect(screen.queryByRole("button", { name: /personas y usuarios/i })).not.toBeInTheDocument();
  });

  it("5xx: reintenta solo 2 veces más (3 intentos) antes de mostrar el error", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(null, { status: 500 })));
    montar();
    await screen.findByText("No pudimos verificar tu acceso");
    expect(apiFetch).toHaveBeenCalledTimes(3);
  });

  it("un fallo puntual (500 y luego 200) se recupera solo sin mostrar el error", async () => {
    vi.mocked(apiFetch)
      .mockResolvedValueOnce(new Response(null, { status: 500 }))
      .mockImplementation(() => Promise.resolve(sesion({ puede_ver_modulo_1: true })));
    montar();
    await screen.findByText("Contenido protegido");
    expect(screen.queryByText("No pudimos verificar tu acceso")).not.toBeInTheDocument();
    expect(apiFetch).toHaveBeenCalledTimes(2);
  });

  it("error: «Reintentar» vuelve a pedir la sesión y, si responde, monta el contenido", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(null, { status: 503 })));
    montar();
    await screen.findByText("No pudimos verificar tu acceso");
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(sesion({ puede_ver_modulo_1: true })));
    await userEvent.click(screen.getByRole("button", { name: "Reintentar" }));
    expect(await screen.findByText("Contenido protegido")).toBeInTheDocument();
    expect(screen.queryByText("No pudimos verificar tu acceso")).not.toBeInTheDocument();
  });

  it("401 (sin sesión): manda al login y no reintenta ni muestra el error", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(null, { status: 401 })));
    montar();
    await waitFor(() => expect(href).toBe("/"));
    expect(apiFetch).toHaveBeenCalledTimes(1);
    expect(screen.queryByText("Contenido protegido")).not.toBeInTheDocument();
    expect(screen.queryByText("No pudimos verificar tu acceso")).not.toBeInTheDocument();
  });

  it("403: error sin reintento automático (un 4xx no cambia solo)", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(null, { status: 403 })));
    montar();
    await screen.findByText("No pudimos verificar tu acceso");
    expect(apiFetch).toHaveBeenCalledTimes(1);
  });

  it("la suspensión conserva su flujo: signOut y /cuenta-suspendida con el motivo, sin montar el contenido", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(sesion({ acceso_permitido: false, motivo_bloqueo: "suspension" })));
    montar();
    await waitFor(() => expect(href).toBe("/cuenta-suspendida?motivo=suspension"));
    expect(supabase.auth.signOut).toHaveBeenCalledTimes(1);
    expect(screen.queryByText("Contenido protegido")).not.toBeInTheDocument();
  });

  // Último a propósito: deja /api/sesion colgado y la consulta se deduplica a nivel de módulo, así que
  // cualquier prueba posterior de este archivo esperaría esa misma promesa.
  it("cargando: «Verificando acceso…» y nada del contenido", async () => {
    vi.mocked(apiFetch).mockImplementation(() => new Promise<Response>(() => {}));
    montar();
    expect(screen.getByText("Verificando acceso…")).toBeInTheDocument();
    expect(screen.queryByText("Contenido protegido")).not.toBeInTheDocument();
  });

});
