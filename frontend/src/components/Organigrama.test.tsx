import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import {
  construirBosque,
  descendientesIncluidoSiMismo,
  filtrarBosque,
  Organigrama,
  type PuestoOrganigrama,
} from "./Organigrama";

const DIRECCION: PuestoOrganigrama = {
  id: "direccion",
  nombre_puesto: "Dirección General",
  reporta_a_id: null,
  activo: true,
  plazas_totales: 1,
};
const GERENCIA_COMERCIAL: PuestoOrganigrama = {
  id: "gerencia-comercial",
  nombre_puesto: "Gerencia Comercial",
  reporta_a_id: "direccion",
  activo: true,
  plazas_totales: 1,
};
const GERENTE_VENTAS: PuestoOrganigrama = {
  id: "gerente-ventas",
  nombre_puesto: "Gerente de Ventas Nacionales",
  reporta_a_id: "gerencia-comercial",
  activo: true,
  plazas_totales: 1,
};
const EJECUTIVO_SENIOR: PuestoOrganigrama = {
  id: "ejecutivo-senior",
  nombre_puesto: "Ejecutivo de Cuenta Senior",
  reporta_a_id: "gerente-ventas",
  activo: true,
  plazas_totales: 2,
};
const GERENTE_TI: PuestoOrganigrama = {
  id: "gerente-ti",
  nombre_puesto: "Gerente o Encargado de TI",
  reporta_a_id: "direccion",
  activo: false,
  plazas_totales: 1,
};

const PUESTOS = [DIRECCION, GERENCIA_COMERCIAL, GERENTE_VENTAS, EJECUTIVO_SENIOR, GERENTE_TI];

describe("construirBosque", () => {
  it("arma un árbol desde reporta_a_id, con la raíz sin padre arriba de todo", () => {
    const bosque = construirBosque(PUESTOS);
    expect(bosque).toHaveLength(1);
    expect(bosque[0].puesto.id).toBe("direccion");
    expect(bosque[0].hijos.map((h) => h.puesto.id).sort()).toEqual(
      ["gerencia-comercial", "gerente-ti"].sort()
    );
  });

  it("anida varios niveles de profundidad", () => {
    const bosque = construirBosque(PUESTOS);
    const gerenciaComercial = bosque[0].hijos.find((h) => h.puesto.id === "gerencia-comercial")!;
    expect(gerenciaComercial.hijos).toHaveLength(1);
    expect(gerenciaComercial.hijos[0].puesto.id).toBe("gerente-ventas");
    expect(gerenciaComercial.hijos[0].hijos[0].puesto.id).toBe("ejecutivo-senior");
  });

  it("trata un reporta_a_id que apunta a un puesto inexistente como raíz propia (sin huérfanos)", () => {
    const conHuerfano: PuestoOrganigrama = {
      id: "huerfano",
      nombre_puesto: "Puesto Huérfano",
      reporta_a_id: "no-existe",
      activo: true,
      plazas_totales: 1,
    };
    const bosque = construirBosque([...PUESTOS, conHuerfano]);
    expect(bosque.some((raiz) => raiz.puesto.id === "huerfano")).toBe(true);
  });

  it("soporta más de un puesto tope (más de una raíz)", () => {
    const otraRaiz: PuestoOrganigrama = {
      id: "otra-direccion",
      nombre_puesto: "Otra Dirección",
      reporta_a_id: null,
      activo: true,
      plazas_totales: 1,
    };
    const bosque = construirBosque([...PUESTOS, otraRaiz]);
    expect(bosque).toHaveLength(2);
  });
});

describe("descendientesIncluidoSiMismo", () => {
  it("incluye al propio puesto y a todos sus descendientes, sin incluir hermanos ni ancestros", () => {
    const set = descendientesIncluidoSiMismo(PUESTOS, "gerencia-comercial");
    expect([...set].sort()).toEqual(
      ["gerencia-comercial", "gerente-ventas", "ejecutivo-senior"].sort()
    );
    expect(set.has("direccion")).toBe(false);
    expect(set.has("gerente-ti")).toBe(false);
  });

  it("una hoja sin hijos sólo se incluye a sí misma", () => {
    const set = descendientesIncluidoSiMismo(PUESTOS, "ejecutivo-senior");
    expect([...set]).toEqual(["ejecutivo-senior"]);
  });
});

describe("filtrarBosque", () => {
  it("sin consulta, devuelve el bosque sin tocar", () => {
    const bosque = construirBosque(PUESTOS);
    expect(filtrarBosque(bosque, "")).toBe(bosque);
  });

  it("conserva el camino hacia un descendiente que coincide, aunque el nodo mismo no matchee", () => {
    const bosque = construirBosque(PUESTOS);
    const filtrado = filtrarBosque(bosque, "ejecutivo");
    // la raíz (Dirección General) no matchea "ejecutivo" pero se conserva porque es ancestro
    expect(filtrado).toHaveLength(1);
    expect(filtrado[0].puesto.id).toBe("direccion");
    // sólo la rama de Gerencia Comercial sobrevive (Gerente de TI no tiene "ejecutivo" en su árbol)
    expect(filtrado[0].hijos.map((h) => h.puesto.id)).toEqual(["gerencia-comercial"]);
  });

  it("sin coincidencias, devuelve un bosque vacío", () => {
    const bosque = construirBosque(PUESTOS);
    expect(filtrarBosque(bosque, "no existe ningún puesto así")).toEqual([]);
  });
});

describe("Organigrama (render)", () => {
  it("pinta cada puesto del bosque con su conteo de ocupadas/plazas", () => {
    const bosque = construirBosque(PUESTOS);
    render(
      <Organigrama
        bosque={bosque}
        ocupadasPorPuesto={{ "ejecutivo-senior": 2 }}
        onSeleccionarPuesto={vi.fn()}
      />
    );

    expect(screen.getByText("Dirección General")).toBeInTheDocument();
    expect(screen.getByText("Ejecutivo de Cuenta Senior")).toBeInTheDocument();
    expect(screen.getByText("2/2 ocupadas")).toBeInTheDocument();
  });

  it("sin ocupadasPorPuesto, degrada a mostrar sólo el total de plazas", () => {
    const bosque = construirBosque(PUESTOS);
    render(<Organigrama bosque={bosque} onSeleccionarPuesto={vi.fn()} />);
    const nodo = screen.getByText("Ejecutivo de Cuenta Senior").closest('[role="button"]')!;
    expect(nodo).toHaveTextContent("2 plazas");
  });

  it("marca un puesto inactivo", () => {
    const bosque = construirBosque(PUESTOS);
    render(<Organigrama bosque={bosque} onSeleccionarPuesto={vi.fn()} />);
    expect(screen.getByText("Inactivo")).toBeInTheDocument();
  });

  it("click en un nodo llama a onSeleccionarPuesto con ese puesto", async () => {
    const bosque = construirBosque(PUESTOS);
    const onSeleccionarPuesto = vi.fn();
    render(<Organigrama bosque={bosque} onSeleccionarPuesto={onSeleccionarPuesto} />);

    await userEvent.click(screen.getByText("Gerencia Comercial"));
    expect(onSeleccionarPuesto).toHaveBeenCalledWith(
      expect.objectContaining({ id: "gerencia-comercial" })
    );
  });

  it("el nodo es accesible por teclado (rol button, activable con Enter)", async () => {
    const bosque = construirBosque(PUESTOS);
    const onSeleccionarPuesto = vi.fn();
    render(<Organigrama bosque={bosque} onSeleccionarPuesto={onSeleccionarPuesto} />);

    const nodo = screen.getByText("Gerente de Ventas Nacionales").closest('[role="button"]')!;
    (nodo as HTMLElement).focus();
    await userEvent.keyboard("{Enter}");
    expect(onSeleccionarPuesto).toHaveBeenCalledWith(
      expect.objectContaining({ id: "gerente-ventas" })
    );
  });
});
