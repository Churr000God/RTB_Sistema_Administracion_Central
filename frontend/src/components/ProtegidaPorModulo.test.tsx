import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { ProtegidaPorModulo } from "./ProtegidaPorModulo";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

function sesion(extra: Record<string, unknown>) {
  vi.mocked(apiFetch).mockImplementation(() =>
    Promise.resolve(new Response(JSON.stringify({ acceso_permitido: true, puede_ver_modulo_1: true, ...extra }))),
  );
}

const Hijo = () => <p>Directorio de personas</p>;

describe("ProtegidaPorModulo", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("con el módulo: muestra la pantalla", async () => {
    sesion({ puede_ver_modulo_1: true });
    render(<ProtegidaPorModulo campo="puede_ver_modulo_1"><Hijo /></ProtegidaPorModulo>);
    expect(await screen.findByText("Directorio de personas")).toBeInTheDocument();
  });

  it("sin el módulo: aviso de acceso no autorizado en vez de la pantalla, con enlace a Inicio", async () => {
    sesion({ puede_ver_modulo_1: false });
    render(<ProtegidaPorModulo campo="puede_ver_modulo_1"><Hijo /></ProtegidaPorModulo>);
    expect(await screen.findByText(/no tienes acceso a esta sección/i)).toBeInTheDocument();
    expect(screen.queryByText("Directorio de personas")).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: /ir a inicio/i })).toHaveAttribute("href", "/inicio");
  });

  it("si la sesión no se pudo leer, NO monta la pantalla (error con Reintentar), ya no hay fail-open", async () => {
    vi.mocked(apiFetch).mockRejectedValue(new Error("sin red"));
    render(<ProtegidaPorModulo campo="puede_ver_modulo_1"><Hijo /></ProtegidaPorModulo>);
    expect(await screen.findByText("No pudimos verificar tu acceso")).toBeInTheDocument();
    expect(screen.queryByText("Directorio de personas")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Reintentar" })).toBeInTheDocument();
  });

  it("una bandera ausente con la sesión cargada bloquea (fail-closed): sólo un true da paso", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(JSON.stringify({ acceso_permitido: true }))));
    render(<ProtegidaPorModulo campo="puede_ver_modulo_1"><Hijo /></ProtegidaPorModulo>);
    expect(await screen.findByText(/no tienes acceso a esta sección/i)).toBeInTheDocument();
    expect(screen.queryByText("Directorio de personas")).not.toBeInTheDocument();
  });

  // Último a propósito: deja /api/sesion colgado y consultarSesion() deduplica a nivel de módulo, así que
  // cualquier prueba posterior de este archivo quedaría esperando esa misma promesa.
  it("mientras carga la sesión no monta la pantalla (no pide datos de más)", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) =>
      path === "/api/sesion" ? new Promise<Response>(() => {}) : Promise.resolve(new Response("{}")),
    );
    render(<ProtegidaPorModulo campo="puede_ver_modulo_1"><Hijo /></ProtegidaPorModulo>);
    expect(screen.queryByText("Directorio de personas")).not.toBeInTheDocument();
  });

});
