import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
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

const MENSAJE_SIN_PUESTO = "Tu acceso está en configuración. Avisa a Recursos Humanos para que te asignen un puesto.";

function sesion(extra: Record<string, unknown> = {}) {
  vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(JSON.stringify({ ...SESION, ...extra }))));
}

describe("InicioPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("sin ningún módulo: nombre, estado, correo y el aviso de acceso en configuración", async () => {
    sesion();
    render(<InicioPage />);
    expect(await screen.findByText("Hola, mariana.alcantara")).toBeInTheDocument();
    expect(screen.getByText("Activo")).toBeInTheDocument();
    expect(screen.getByText("mariana@example.com")).toBeInTheDocument();
    expect(screen.getByText(MENSAJE_SIN_PUESTO)).toBeInTheDocument();
    expect(screen.queryByText(/estos son tus accesos/i)).not.toBeInTheDocument();
  });

  it("con algún módulo: saludo y enlaces SOLO a los que ve, y NO el aviso de «aún no tienes puesto»", async () => {
    sesion({ puede_ver_modulo_1: true, puede_ver_modulo_3: true });
    render(<InicioPage />);
    expect(await screen.findByText("Hola, mariana.alcantara")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Personas y Usuarios" })).toHaveAttribute("href", "/personas");
    expect(screen.getByRole("link", { name: "Tiempo" })).toHaveAttribute("href", "/tiempo/asignacion-jornada");
    expect(screen.queryByRole("link", { name: "Estructura organizacional" })).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "Terminales" })).not.toBeInTheDocument();
    expect(screen.queryByText(MENSAJE_SIN_PUESTO)).not.toBeInTheDocument();
  });

  it("con módulo sólo de Terminales también ofrece su acceso", async () => {
    sesion({ puede_ver_terminales: true });
    render(<InicioPage />);
    expect(await screen.findByRole("link", { name: "Terminales" })).toHaveAttribute("href", "/tiempo/terminales");
    expect(screen.queryByText(MENSAJE_SIN_PUESTO)).not.toBeInTheDocument();
  });

  it("sólo pide la sesión propia: no consulta listas ni datos de otras personas", async () => {
    sesion({ puede_ver_modulo_1: true });
    render(<InicioPage />);
    await screen.findByText("Hola, mariana.alcantara");
    const rutas = vi.mocked(apiFetch).mock.calls.map(([p]) => String(p));
    expect(rutas.every((r) => r === "/api/sesion")).toBe(true);
  });

  it("los textos del servidor se pintan como texto plano", async () => {
    sesion({ nombre_usuario: "<img src=x onerror=alert(1)>" });
    const { container } = render(<InicioPage />);
    expect(await screen.findByText(/<img src=x onerror=alert\(1\)>/)).toBeInTheDocument();
    expect(container.querySelector("img[src='x']")).toBeNull();
  });

  it("sin nombre/estado/correo legibles no rompe: saludo genérico y «—»", async () => {
    sesion({ nombre_usuario: null, persona_estado: null, correo: null });
    render(<InicioPage />);
    expect(await screen.findByText("Hola")).toBeInTheDocument();
    expect(screen.getAllByText("—").length).toBeGreaterThanOrEqual(2);
  });

  it("estado de suspensión legible", async () => {
    sesion({ persona_estado: "suspension" });
    render(<InicioPage />);
    expect(await screen.findByText("Suspensión")).toBeInTheDocument();
  });

  it("si la sesión no se puede verificar (500): «No pudimos verificar tu acceso» con Reintentar, nunca el aviso de sin puesto ni accesos", async () => {
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(null, { status: 500 })));
    render(<InicioPage />);
    expect(await screen.findByText("No pudimos verificar tu acceso")).toBeInTheDocument();
    expect(screen.queryByText(MENSAJE_SIN_PUESTO)).not.toBeInTheDocument();
    expect(screen.queryByText(/estos son tus accesos/i)).not.toBeInTheDocument();
    vi.mocked(apiFetch).mockImplementation(() => Promise.resolve(new Response(JSON.stringify({ ...SESION, puede_ver_modulo_1: true }))));
    await userEvent.click(screen.getAllByRole("button", { name: "Reintentar" })[0]);
    await waitFor(() => expect(screen.getByRole("link", { name: "Personas y Usuarios" })).toBeInTheDocument());
  });
});
