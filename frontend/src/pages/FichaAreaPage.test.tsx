import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { FichaAreaPage } from "./FichaAreaPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const AREA = {
  id: "33333333-3333-3333-3333-333333333333",
  nombre_area: "Comercial",
  activo: true,
  creado_en: "2026-08-31T00:00:00+00:00",
  actualizado_en: "2026-08-31T00:00:00+00:00",
};

function mockApiFetch(area = AREA, departamentos: unknown = []) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path === "/api/departamentos") {
      return Promise.resolve(new Response(JSON.stringify(departamentos)));
    }
    return Promise.resolve(new Response(JSON.stringify(area)));
  });
}

function renderPagina() {
  render(
    <MemoryRouter initialEntries={[`/estructura/areas/${AREA.id}`]}>
      <Routes>
        <Route path="/estructura/areas/:id" element={<FichaAreaPage />} />
      </Routes>
    </MemoryRouter>
  );
}

describe("FichaAreaPage", () => {
  it("muestra el nombre y el estado del área", async () => {
    mockApiFetch();
    renderPagina();

    await waitFor(() => expect(screen.getAllByText("Comercial").length).toBeGreaterThan(0));
    expect(screen.getByText("Activo")).toBeInTheDocument();
  });

  it("renombra el área vía PATCH /api/areas/:id", async () => {
    let renombrada = false;
    vi.mocked(apiFetch).mockImplementation((path: string, opciones?: RequestInit) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path === `/api/areas/${AREA.id}` && opciones?.method === "PATCH") {
        renombrada = true;
        return Promise.resolve(
          new Response(JSON.stringify({ ...AREA, nombre_area: "Comercial y Marketing" }))
        );
      }
      if (path === "/api/departamentos") {
        return Promise.resolve(new Response(JSON.stringify([])));
      }
      return Promise.resolve(new Response(JSON.stringify(AREA)));
    });

    renderPagina();
    await waitFor(() => expect(screen.getAllByText("Comercial").length).toBeGreaterThan(0));

    const campoNombre = screen.getByLabelText(/^nombre$/i);
    await userEvent.clear(campoNombre);
    await userEvent.type(campoNombre, "Comercial y Marketing");
    await userEvent.click(screen.getByRole("button", { name: /guardar/i }));

    await waitFor(() => expect(renombrada).toBe(true));
    await waitFor(() =>
      expect(screen.getAllByText("Comercial y Marketing").length).toBeGreaterThan(0)
    );
  });

  it("muestra error de nombre duplicado al renombrar (409)", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string, opciones?: RequestInit) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path === `/api/areas/${AREA.id}` && opciones?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 409 }));
      }
      if (path === "/api/departamentos") {
        return Promise.resolve(new Response(JSON.stringify([])));
      }
      return Promise.resolve(new Response(JSON.stringify(AREA)));
    });

    renderPagina();
    await waitFor(() => expect(screen.getAllByText("Comercial").length).toBeGreaterThan(0));
    await userEvent.click(screen.getByRole("button", { name: /guardar/i }));

    await waitFor(() =>
      expect(screen.getByText(/ya existe un área con ese nombre/i)).toBeInTheDocument()
    );
  });

  it("desactiva el área vía PATCH /api/areas/:id/estado", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string, opciones?: RequestInit) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path === `/api/areas/${AREA.id}/estado` && opciones?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify({ ...AREA, activo: false })));
      }
      if (path === "/api/departamentos") {
        return Promise.resolve(new Response(JSON.stringify([])));
      }
      return Promise.resolve(new Response(JSON.stringify(AREA)));
    });

    renderPagina();
    await waitFor(() => expect(screen.getAllByText("Comercial").length).toBeGreaterThan(0));
    await userEvent.click(screen.getByRole("button", { name: /desactivar área/i }));

    await waitFor(() => expect(screen.getByText("Inactivo")).toBeInTheDocument());
    expect(screen.getByRole("button", { name: /reactivar área/i })).toBeInTheDocument();
  });

  it("mientras el PATCH de estado está en curso, el botón se deshabilita y avisa — un segundo click no dispara un segundo PATCH", async () => {
    let resolverPatch!: (respuesta: Response) => void;
    let llamadasPatch = 0;
    vi.mocked(apiFetch).mockImplementation((path: string, opciones?: RequestInit) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path === `/api/areas/${AREA.id}/estado` && opciones?.method === "PATCH") {
        llamadasPatch += 1;
        return new Promise<Response>((resolver) => {
          resolverPatch = resolver;
        });
      }
      if (path === "/api/departamentos") {
        return Promise.resolve(new Response(JSON.stringify([])));
      }
      return Promise.resolve(new Response(JSON.stringify(AREA)));
    });

    renderPagina();
    await waitFor(() => expect(screen.getAllByText("Comercial").length).toBeGreaterThan(0));

    const boton = screen.getByRole("button", { name: /desactivar área/i });
    await userEvent.click(boton);

    await waitFor(() => expect(screen.getByRole("button", { name: /desactivando/i })).toBeDisabled());
    // el botón deshabilitado de verdad (no sólo visual) evita el segundo submit real
    await userEvent.click(screen.getByRole("button", { name: /desactivando/i }));
    expect(llamadasPatch).toBe(1);

    resolverPatch(new Response(JSON.stringify({ ...AREA, activo: false })));
    await waitFor(() => expect(screen.getByText("Inactivo")).toBeInTheDocument());
  });

  it("reactiva un área inactiva vía PATCH /api/areas/:id/estado", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string, opciones?: RequestInit) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path === `/api/areas/${AREA.id}/estado` && opciones?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify({ ...AREA, activo: true })));
      }
      if (path === "/api/departamentos") {
        return Promise.resolve(new Response(JSON.stringify([])));
      }
      return Promise.resolve(new Response(JSON.stringify({ ...AREA, activo: false })));
    });

    renderPagina();
    await waitFor(() => expect(screen.getByText("Inactivo")).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: /reactivar área/i }));

    await waitFor(() => expect(screen.getByText("Activo")).toBeInTheDocument());
  });

  it("si GET /api/areas/:id falla, muestra error con reintentar", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      return Promise.resolve(new Response(null, { status: 500 }));
    });

    renderPagina();

    await waitFor(() =>
      expect(screen.getByText(/no se pudo cargar esta área/i)).toBeInTheDocument()
    );
    expect(screen.getByRole("button", { name: /reintentar/i })).toBeInTheDocument();
  });

  describe("departamentos de esta área", () => {
    const DEPARTAMENTO_ACTIVO = {
      id: "dep-activo-1",
      area_id: AREA.id,
      nombre_departamento: "Ventas",
      activo: true,
    };
    const DEPARTAMENTO_INACTIVO = {
      id: "dep-inactivo-1",
      area_id: AREA.id,
      nombre_departamento: "Marketing (histórico)",
      activo: false,
    };
    const DEPARTAMENTO_DE_OTRA_AREA = {
      id: "dep-otra-area",
      area_id: "otra-area-cualquiera",
      nombre_departamento: "No debería aparecer",
      activo: true,
    };

    it("lista los departamentos activos e inactivos de esta área, filtrando los de otras áreas", async () => {
      mockApiFetch(AREA, [DEPARTAMENTO_ACTIVO, DEPARTAMENTO_INACTIVO, DEPARTAMENTO_DE_OTRA_AREA]);
      renderPagina();

      await waitFor(() => expect(screen.getByText("Ventas")).toBeInTheDocument());
      expect(screen.getByText("Marketing (histórico)")).toBeInTheDocument();
      expect(screen.queryByText("No debería aparecer")).not.toBeInTheDocument();

      const enlaceActivo = screen.getByRole("link", { name: "Ventas" });
      expect(enlaceActivo).toHaveAttribute("href", `/estructura/departamentos/${DEPARTAMENTO_ACTIVO.id}`);
      const enlaceInactivo = screen.getByRole("link", { name: "Marketing (histórico)" });
      expect(enlaceInactivo).toHaveAttribute(
        "href",
        `/estructura/departamentos/${DEPARTAMENTO_INACTIVO.id}`
      );

      expect(screen.getByText("Activos")).toBeInTheDocument();
      expect(screen.getByText("Inactivos")).toBeInTheDocument();
    });

    it("muestra un estado vacío si el área no tiene departamentos", async () => {
      mockApiFetch(AREA, []);
      renderPagina();

      await waitFor(() => expect(screen.getAllByText("Comercial").length).toBeGreaterThan(0));
      expect(screen.getByText("Esta área no tiene departamentos registrados.")).toBeInTheDocument();
    });

    it("si GET /api/departamentos responde 403, muestra el aviso de sin permiso sin romper el resto de la página", async () => {
      vi.mocked(apiFetch).mockImplementation((path: string) => {
        if (path === "/api/sesion") {
          return Promise.resolve(
            new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
          );
        }
        if (path === "/api/departamentos") {
          return Promise.resolve(new Response(null, { status: 403 }));
        }
        return Promise.resolve(new Response(JSON.stringify(AREA)));
      });
      renderPagina();

      await waitFor(() => expect(screen.getAllByText("Comercial").length).toBeGreaterThan(0));
      expect(
        screen.getByText("No tienes permiso para ver los departamentos de esta área.")
      ).toBeInTheDocument();
      // el resto de la ficha (nombre, botón desactivar) sigue disponible: el 403 no rompe la página
      expect(screen.getByRole("button", { name: /desactivar área/i })).toBeInTheDocument();
    });

    it("si GET /api/departamentos falla con otro error, muestra un aviso genérico en la tarjeta", async () => {
      vi.mocked(apiFetch).mockImplementation((path: string) => {
        if (path === "/api/sesion") {
          return Promise.resolve(
            new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
          );
        }
        if (path === "/api/departamentos") {
          return Promise.resolve(new Response(null, { status: 500 }));
        }
        return Promise.resolve(new Response(JSON.stringify(AREA)));
      });
      renderPagina();

      await waitFor(() => expect(screen.getAllByText("Comercial").length).toBeGreaterThan(0));
      expect(
        screen.getByText("No se pudieron cargar los departamentos de esta área.")
      ).toBeInTheDocument();
    });
  });
});
