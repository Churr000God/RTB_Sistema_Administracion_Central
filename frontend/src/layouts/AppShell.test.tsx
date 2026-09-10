import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { StrictMode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

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
      new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }), { status: 200 })
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

  it("si /api/sesion falla, no bloquea: muestra el shell igual (fail-open)", async () => {
    vi.mocked(apiFetch).mockRejectedValue(new Error("network down"));

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
    expect(supabase.auth.signOut).not.toHaveBeenCalled();
  });

  it("si /api/sesion responde con error HTTP, tampoco bloquea (fail-open)", async () => {
    vi.mocked(apiFetch).mockResolvedValue(new Response(null, { status: 500 }));

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
    expect(supabase.auth.signOut).not.toHaveBeenCalled();
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
      new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }), { status: 200 })
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
      new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }), { status: 200 })
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
      new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }), { status: 200 })
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
      new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }), { status: 200 })
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

  it("si /api/sesion falla (fail-open), muestra ambos grupos aunque no se sepan los permisos reales", async () => {
    vi.mocked(apiFetch).mockRejectedValue(new Error("network down"));

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
    expect(screen.getByRole("button", { name: /personas y usuarios/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /estructura organizacional/i })).toBeInTheDocument();
  });

  it("un grupo sin items propios (p. ej. Panel) se muestra atenuado y sin botón expandible", async () => {
    vi.mocked(apiFetch).mockResolvedValue(
      new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }), { status: 200 })
    );

    render(
      <AppShell>
        <p>Contenido protegido</p>
      </AppShell>
    );

    await waitFor(() => expect(screen.getByText("Contenido protegido")).toBeInTheDocument());
    const panel = screen.getByText("Panel").closest("[aria-disabled]");
    expect(panel).toHaveAttribute("aria-disabled", "true");
    expect(screen.queryByRole("button", { name: /^panel$/i })).not.toBeInTheDocument();
  });
});
