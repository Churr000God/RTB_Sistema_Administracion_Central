import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { RevocarPermisoPage } from "./RevocarPermisoPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const PUESTO_PERMISO_ID = "puesto-permiso-ficticio-1";

const VIGENTES = [
  { id: PUESTO_PERMISO_ID, puesto_id: "puesto-ficticio-1", nombre_puesto: "Puesto Ficticio Uno", codigo: "permiso_ficticio_uno", activo: true },
  { id: "puesto-permiso-ficticio-2", puesto_id: "puesto-ficticio-2", nombre_puesto: "Puesto Ficticio Dos", codigo: "permiso_ficticio_dos", activo: true },
];

function mockApiFetch(overrides: { vigentes?: Response; post?: (init: RequestInit) => Response }) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path === "/api/permisos/revocar" && init?.method === "POST") {
      return Promise.resolve(
        overrides.post ? overrides.post(init) : new Response(JSON.stringify({ id: PUESTO_PERMISO_ID }))
      );
    }
    if (path === "/api/permisos/vigentes") {
      return Promise.resolve(overrides.vigentes ?? new Response(JSON.stringify(VIGENTES)));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

function renderPagina(id = PUESTO_PERMISO_ID, query = "") {
  render(
    <MemoryRouter initialEntries={[`/estructura/permisos/${id}/revocar${query}`]}>
      <Routes>
        <Route path="/estructura/permisos/:id/revocar" element={<RevocarPermisoPage />} />
      </Routes>
    </MemoryRouter>
  );
}

describe("RevocarPermisoPage", () => {
  it("muestra el puesto y el código del permiso a revocar (buscado en /api/permisos/vigentes)", async () => {
    mockApiFetch({});
    renderPagina();

    await waitFor(() => expect(screen.getByText("Puesto Ficticio Uno")).toBeInTheDocument());
    expect(screen.getByText(/permiso: permiso_ficticio_uno/i)).toBeInTheDocument();
  });

  it("envía puesto_permiso_id a POST /api/permisos/revocar al confirmar", async () => {
    mockApiFetch({});
    renderPagina();
    await waitFor(() => expect(screen.getByText("Puesto Ficticio Uno")).toBeInTheDocument());

    await userEvent.click(screen.getByRole("button", { name: /confirmar revocación/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/permisos/revocar",
        expect.objectContaining({ method: "POST" })
      )
    );
    const llamada = vi
      .mocked(apiFetch)
      .mock.calls.find(([path, init]) => path === "/api/permisos/revocar" && (init as RequestInit)?.method === "POST")!;
    const cuerpo = JSON.parse(llamada[1]!.body as string);
    expect(cuerpo.puesto_permiso_id).toBe(PUESTO_PERMISO_ID);
  });

  it("muestra el detail real del backend cuando sería la última fila activa de puesto_permiso_edicion (422)", async () => {
    mockApiFetch({
      post: () =>
        new Response(
          JSON.stringify({
            detail: "No se puede revocar: dejaría al sistema sin nadie que pueda repartir permisos.",
          }),
          { status: 422 }
        ),
    });
    renderPagina();
    await waitFor(() => expect(screen.getByText("Puesto Ficticio Uno")).toBeInTheDocument());

    await userEvent.click(screen.getByRole("button", { name: /confirmar revocación/i }));

    await waitFor(() =>
      expect(
        screen.getByText(
          "No se puede revocar: dejaría al sistema sin nadie que pueda repartir permisos."
        )
      ).toBeInTheDocument()
    );
  });

  it("muestra 'no se encontró' y deshabilita confirmar cuando el id no está entre los vigentes", async () => {
    mockApiFetch({});
    renderPagina("puesto-permiso-inexistente");

    await waitFor(() =>
      expect(screen.getByText(/no se encontró este otorgamiento de permiso/i)).toBeInTheDocument()
    );
    expect(screen.getByRole("button", { name: /confirmar revocación/i })).toBeDisabled();
  });

  it("muestra un error si falla la carga de /api/permisos/vigentes", async () => {
    mockApiFetch({ vigentes: new Response(null, { status: 500 }) });
    renderPagina();

    await waitFor(() =>
      expect(
        screen.getByText(/no se pudo cargar este otorgamiento de permiso/i)
      ).toBeInTheDocument()
    );
  });

  describe("navegación de vuelta (deep-link ?puesto_id= desde la ficha de un puesto)", () => {
    const locationOriginal = window.location;

    afterEach(() => {
      // jsdom no implementa navegación real (`window.location.href = x` no actualiza
      // `location`, sólo tira "Not implemented: navigation" a stderr) — no hay forma de
      // observar el destino de la redirección sin reemplazar location por un objeto plano
      // asignable. Se restaura el real después de cada test para no afectar otros archivos.
      Object.defineProperty(window, "location", { writable: true, value: locationOriginal });
    });

    function stubLocation(search: string) {
      const pathname = `/estructura/permisos/${PUESTO_PERMISO_ID}/revocar`;
      Object.defineProperty(window, "location", {
        writable: true,
        value: { pathname, search, href: `${pathname}${search}` },
      });
    }

    it("con ?puesto_id=, Cancelar y una revocación exitosa vuelven a la ficha de ese puesto", async () => {
      stubLocation("?puesto_id=puesto-ficticio-1");
      mockApiFetch({});
      renderPagina();
      await waitFor(() => expect(screen.getByText("Puesto Ficticio Uno")).toBeInTheDocument());

      expect(screen.getByRole("link", { name: /cancelar/i })).toHaveAttribute(
        "href",
        "/estructura/puestos/puesto-ficticio-1"
      );

      await userEvent.click(screen.getByRole("button", { name: /confirmar revocación/i }));

      await waitFor(() =>
        expect(window.location.href).toBe("/estructura/puestos/puesto-ficticio-1")
      );
    });

    it("sin ?puesto_id= (llegado por otro camino), mantiene el comportamiento actual: vuelve a Permisos", async () => {
      stubLocation("");
      mockApiFetch({});
      renderPagina();
      await waitFor(() => expect(screen.getByText("Puesto Ficticio Uno")).toBeInTheDocument());

      expect(screen.getByRole("link", { name: /cancelar/i })).toHaveAttribute(
        "href",
        "/estructura/permisos"
      );

      await userEvent.click(screen.getByRole("button", { name: /confirmar revocación/i }));

      await waitFor(() => expect(window.location.href).toBe("/estructura/permisos"));
    });
  });
});
