import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { InicioPage } from "./InicioPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const SESION = {
  auth_user_id: "u1",
  correo: "mariana@example.com",
  nombre_usuario: "mariana.alcantara",
  persona_id: "p1",
  persona_estado: "activo",
  acceso_permitido: true,
  motivo_bloqueo: null,
  puede_ver_modulo_1: false,
  puede_ver_modulo_2: false,
  puede_ver_modulo_3: false,
};

describe("InicioPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("muestra el nombre, el estado, el correo y el mensaje de acceso en configuración", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(JSON.stringify(SESION))));
    render(<InicioPage />);
    expect(await screen.findByText("Hola, mariana.alcantara")).toBeInTheDocument();
    expect(screen.getByText("Activo")).toBeInTheDocument();
    expect(screen.getByText("mariana@example.com")).toBeInTheDocument();
    expect(
      screen.getByText("Tu acceso está en configuración. Avisa a Recursos Humanos para que te asignen un puesto."),
    ).toBeInTheDocument();
  });

  it("sólo pide la sesión propia: no consulta listas ni datos de otras personas", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(JSON.stringify(SESION))));
    render(<InicioPage />);
    await screen.findByText("Hola, mariana.alcantara");
    const rutas = vi.mocked(apiFetch).mock.calls.map(([p]) => String(p));
    expect(rutas.every((r) => r === "/api/sesion")).toBe(true);
  });

  it("los textos del servidor se pintan como texto plano", async () => {
    vi.mocked(apiFetch).mockImplementation(() =>
      Promise.resolve(new Response(JSON.stringify({ ...SESION, nombre_usuario: "<img src=x onerror=alert(1)>" }))),
    );
    const { container } = render(<InicioPage />);
    expect(await screen.findByText(/<img src=x onerror=alert\(1\)>/)).toBeInTheDocument();
    expect(container.querySelector("img[src='x']")).toBeNull();
  });

  it("sin datos legibles de la sesión no rompe: saludo genérico y «—»", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) =>
      Promise.resolve(path === "/api/sesion" ? new Response(JSON.stringify({ acceso_permitido: true, puede_ver_modulo_1: false, puede_ver_modulo_2: false, puede_ver_modulo_3: false })) : new Response("{}")),
    );
    render(<InicioPage />);
    expect(await screen.findByText("Hola")).toBeInTheDocument();
    expect(screen.getAllByText("—").length).toBeGreaterThanOrEqual(2);
  });

  it("estado de suspensión legible", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(JSON.stringify({ ...SESION, persona_estado: "suspension" }))));
    render(<InicioPage />);
    expect(await screen.findByText("Suspensión")).toBeInTheDocument();
  });
});
