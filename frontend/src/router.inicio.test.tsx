import { describe, expect, it, vi } from "vitest";

import { InicioPage } from "./pages/InicioPage";
import { RutaVerificada } from "./components/RutaVerificada";
import { router } from "./router";

vi.mock("./lib/supabaseClient", () => ({ supabase: { auth: {} } }));

type RutaObj = { path?: string; element?: { type: unknown; props: Record<string, unknown> }; children?: RutaObj[] };

// Aplana el árbol de rutas: ruta -> bandera que la guarda (null = sin guarda de módulo).
function tablaDeBanderas(): Map<string, string | null> {
  const tabla = new Map<string, string | null>();
  const recorrer = (rutas: RutaObj[], bandera: string | null) => {
    for (const ruta of rutas) {
      const esGuarda = ruta.element?.type === RutaVerificada;
      const siguiente = esGuarda ? String(ruta.element!.props.campo) : bandera;
      if (ruta.path !== undefined) tabla.set(ruta.path, siguiente);
      if (ruta.children) recorrer(ruta.children, siguiente);
    }
  };
  recorrer(router.routes as unknown as RutaObj[], null);
  return tabla;
}

describe("router · tabla ruta -> bandera", () => {
  const tabla = tablaDeBanderas();

  it("/inicio existe, sin guarda de módulo (es para toda persona con sesión)", () => {
    const inicio = (router.routes as unknown as RutaObj[]).find((r) => r.path === "/inicio");
    expect(inicio?.element?.type).toBe(InicioPage);
    expect(tabla.get("/inicio")).toBeNull();
  });

  it("Personas y Usuarios (módulo 1) -> puede_ver_modulo_1: Directorio, alta de persona, alta de usuario, cambio de estado y bitácora de movimientos", () => {
    for (const ruta of ["/personas", "/personas/nueva", "/usuarios/nuevo", "/personas/:id/movimiento", "/personas/:id/bitacora"]) {
      expect(tabla.get(ruta), ruta).toBe("puede_ver_modulo_1");
    }
  });

  it("toda /estructura/* -> puede_ver_modulo_2", () => {
    const rutas = [...tabla.keys()].filter((p) => p.startsWith("/estructura/"));
    expect(rutas.length).toBe(16);
    for (const ruta of rutas) expect(tabla.get(ruta), ruta).toBe("puede_ver_modulo_2");
  });

  it("/tiempo/* que no es de Terminales -> puede_ver_modulo_3", () => {
    const rutas = [...tabla.keys()].filter((p) => p.startsWith("/tiempo/") && !p.startsWith("/tiempo/terminales"));
    expect(rutas.length).toBe(14);
    for (const ruta of rutas) expect(tabla.get(ruta), ruta).toBe("puede_ver_modulo_3");
  });

  it("/tiempo/terminales y todas sus subrutas -> puede_ver_terminales (no modulo_3)", () => {
    const rutas = [...tabla.keys()].filter((p) => p.startsWith("/tiempo/terminales"));
    expect(rutas.sort()).toEqual([
      "/tiempo/terminales",
      "/tiempo/terminales/:id/usuarios",
      "/tiempo/terminales/anomalias",
      "/tiempo/terminales/configuracion",
      "/tiempo/terminales/configuracion/activacion-por-huella",
      "/tiempo/terminales/configuracion/variables",
    ]);
    for (const ruta of rutas) expect(tabla.get(ruta), ruta).toBe("puede_ver_terminales");
  });

  it("ninguna ruta de /estructura o /tiempo queda sin guarda", () => {
    for (const [ruta, bandera] of tabla) {
      if (ruta.startsWith("/estructura/") || ruta.startsWith("/tiempo/")) expect(bandera, ruta).not.toBeNull();
    }
  });

  it("sin guarda de módulo A PROPÓSITO: la ficha y la bitácora de asignaciones (se enlazan desde otros módulos), la autenticación e Inicio", () => {
    // /personas/:id: la ficha se enlaza desde otros módulos y su identidad ya degrada a «—».
    // /personas/:id/bitacora-asignaciones: se enlaza desde Estructura/Asignaciones.
    for (const ruta of ["/personas/:id", "/personas/:id/bitacora-asignaciones"]) {
      expect(tabla.get(ruta), ruta).toBeNull();
    }
    for (const ruta of ["/", "/cuenta-suspendida", "/configurar-2fa", "/verificar-totp", "/olvide-contrasena", "/restablecer-contrasena", "/completar-invitacion", "/inicio"]) {
      expect(tabla.get(ruta), ruta).toBeNull();
    }
  });

  it("la tabla completa queda fijada: las únicas rutas sin guarda son exactamente las anteriores", () => {
    const sinGuarda = [...tabla.entries()].filter(([, bandera]) => bandera === null).map(([ruta]) => ruta).sort();
    expect(sinGuarda).toEqual(
      [
        "/",
        "/cuenta-suspendida",
        "/configurar-2fa",
        "/verificar-totp",
        "/olvide-contrasena",
        "/restablecer-contrasena",
        "/completar-invitacion",
        "/inicio",
        "/personas/:id",
        "/personas/:id/bitacora-asignaciones",
      ].sort(),
    );
  });
});
