import { useEffect, useState, type ReactNode } from "react";
import {
  BarChart3,
  Building2,
  CalendarClock,
  ChevronDown,
  ChevronRight,
  Clock,
  LayoutGrid,
  LogOut,
  Settings,
  ShieldCheck,
  SlidersHorizontal,
  Users,
  type LucideIcon,
} from "lucide-react";

import { supabase } from "../lib/supabaseClient";
import { registrarErrorAuth } from "../lib/erroresAuth";
import { consultarSesion, type SesionOut } from "../lib/sesion";

type EstadoAcceso = "verificando" | "permitido";

type NavItem = { label: string; href: string; disponible: boolean };

// `disponible` (a nivel de grupo y de item) es el punto de enganche del gate de permisos.
// El de "Personas y Usuarios" y "Estructura organizacional" ya se deriva en tiempo real de
// `sesion.puede_ver_modulo_1`/`puede_ver_modulo_2` (ver `gruposConGate` más abajo) — el valor
// puesto acá abajo es sólo el default mientras la sesión no cargó o falló (fail-open). Los
// items DENTRO de cada grupo siguen fijos: no hay granularidad más fina que "el módulo
// completo" todavía.
type NavGroup = { label: string; icono: LucideIcon; disponible: boolean; items: NavItem[] };

const NAV_GROUPS: NavGroup[] = [
  { label: "Panel", icono: LayoutGrid, disponible: false, items: [] },
  {
    label: "Personas y Usuarios",
    icono: Users,
    disponible: true,
    items: [{ label: "Directorio", href: "/personas", disponible: true }],
  },
  {
    label: "Estructura organizacional",
    icono: Building2,
    disponible: true,
    items: [
      { label: "Áreas", href: "/estructura/areas", disponible: true },
      { label: "Departamentos", href: "/estructura/departamentos", disponible: true },
      { label: "Puestos", href: "/estructura/puestos", disponible: true },
      { label: "Asignaciones", href: "/estructura/asignaciones", disponible: true },
      { label: "Permisos", href: "/estructura/permisos", disponible: true },
    ],
  },
  {
    label: "Jornadas",
    icono: CalendarClock,
    disponible: true,
    items: [
      { label: "Asignar jornada", href: "/tiempo/asignacion-jornada", disponible: true },
      { label: "Corridas de batch", href: "/tiempo/corridas-batch", disponible: true },
    ],
  },
  {
    label: "Marcas",
    icono: Clock,
    disponible: true,
    items: [
      { label: "Registro de marcas", href: "/tiempo/marcas", disponible: true },
      { label: "Captura manual de marca", href: "/tiempo/captura-manual", disponible: true },
      { label: "Excepciones pendientes", href: "/tiempo/excepciones", disponible: true },
      { label: "Tramos", href: "/tiempo/tramos", disponible: true },
      { label: "Días", href: "/tiempo/dias", disponible: true },
    ],
  },
  {
    label: "Autorizaciones",
    icono: ShieldCheck,
    disponible: true,
    items: [{ label: "Ausencias pendientes", href: "/tiempo/ausencias", disponible: true }],
  },
  {
    label: "Reportes",
    icono: BarChart3,
    disponible: true,
    items: [
      { label: "Banco de horas", href: "/tiempo/banco-de-horas", disponible: true },
      { label: "Alertas de retardo", href: "/tiempo/alertas-retardo", disponible: true },
    ],
  },
  {
    label: "Parámetros",
    icono: SlidersHorizontal,
    disponible: true,
    items: [
      { label: "Tope legal", href: "/tiempo/parametros/tope-legal", disponible: true },
      { label: "Días festivos", href: "/tiempo/parametros/dias-festivos", disponible: true },
      { label: "Parámetros del sistema", href: "/tiempo/parametros/sistema", disponible: true },
    ],
  },
  { label: "Configuración", icono: Settings, disponible: false, items: [] },
];

type Props = { children: ReactNode };

export function AppShell({ children }: Props) {
  const rutaActual = typeof window !== "undefined" ? window.location.pathname : "";
  const [correoUsuario, setCorreoUsuario] = useState<string | null>(null);
  const [estadoAcceso, setEstadoAcceso] = useState<EstadoAcceso>("verificando");
  const [sesion, setSesion] = useState<SesionOut | null>(null);
  const [gruposAbiertos, setGruposAbiertos] = useState<Set<string>>(
    () =>
      new Set(
        NAV_GROUPS.filter((grupo) =>
          grupo.items.some((item) => item.disponible && rutaActual.startsWith(item.href)),
        ).map((grupo) => grupo.label),
      ),
  );

  function alternarGrupo(label: string) {
    setGruposAbiertos((anterior) => {
      const siguiente = new Set(anterior);
      if (siguiente.has(label)) {
        siguiente.delete(label);
      } else {
        siguiente.add(label);
      }
      return siguiente;
    });
  }

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => {
      setCorreoUsuario(data.user?.email ?? null);
    });
  }, []);

  useEffect(() => {
    // Guard de sesión: LoginPage ya chequea /api/sesion al loguearse, pero eso no cubre a
    // alguien que ya tenía una sesión bloqueada y navega/recarga directo a una ruta interna
    // (AppShell envuelve todas). Fail-open (mismo criterio que LoginPage, D8 del plan): si
    // /api/sesion falla, no se bloquea — la RLS de Postgres sigue siendo el control real.
    // consultarSesion() deduplica la petición a nivel de módulo — con StrictMode este efecto
    // se monta dos veces en dev, y sin deduplicar cada montaje disparaba su propio
    // GET /api/sesion; por timing entre apiFetch/getSession() y el doble montaje, uno de los
    // dos podía salir sin token válido y entrar en fail-open de más, no por una falla real.
    let vivo = true;

    consultarSesion()
      .then(async (sesion) => {
        if (!vivo) return;
        if (!sesion.acceso_permitido) {
          // Una vez confirmado que NO hay acceso, el redirect tiene que pasar sí o sí — que
          // signOut() falle (p. ej. un hiccup de red al llamar a GoTrue, después de que ya
          // limpió la sesión local) no puede tirarnos al .catch() de más abajo y hacer
          // fail-open: eso dejaría a la persona deslogueada en silencio y sin redirigir,
          // viendo la ruta interna rota. El signOut ya limpia localStorage aunque la llamada
          // de red falle, así que igual conviene mandarla a la pantalla de bloqueo.
          try {
            await supabase.auth.signOut();
          } catch (errorSignOut) {
            registrarErrorAuth("AppShell.signOut", errorSignOut);
          }
          window.location.href = `/cuenta-suspendida?motivo=${sesion.motivo_bloqueo ?? "suspension"}`;
          return;
        }
        setSesion(sesion);
        setEstadoAcceso("permitido");
      })
      .catch((error) => {
        registrarErrorAuth("AppShell.sesion", error);
        if (vivo) setEstadoAcceso("permitido");
      });

    return () => {
      vivo = false;
    };
  }, []);

  async function cerrarSesion() {
    await supabase.auth.signOut();
    window.location.href = "/";
  }

  if (estadoAcceso === "verificando") {
    return (
      <div className="app-shell-cargando">
        <p>Verificando acceso…</p>
      </div>
    );
  }

  // Gate real de los dos grupos con módulo: si la sesión no cargó (fail-open, mismo criterio
  // que el guard de arriba) quedan visibles por default en vez de ocultarse por un error de
  // red — la RLS del backend sigue siendo el control real, esto es sólo la UI del sidebar.
  const gruposConGate = NAV_GROUPS.map((grupo) => {
    if (grupo.label === "Personas y Usuarios") {
      return { ...grupo, disponible: sesion?.puede_ver_modulo_1 ?? true };
    }
    if (grupo.label === "Estructura organizacional") {
      return { ...grupo, disponible: sesion?.puede_ver_modulo_2 ?? true };
    }
    if (
      grupo.label === "Jornadas" ||
      grupo.label === "Marcas" ||
      grupo.label === "Autorizaciones" ||
      grupo.label === "Reportes" ||
      grupo.label === "Parámetros"
    ) {
      // Un solo permiso (ver_modulo_3) cubre las 5 — no hay ver_modulo_4/5 por separado,
      // el catálogo de permisos de Tiempo (33_*.sql) sólo define uno para todo el módulo. El
      // permiso fino de lectura (banco_de_horas_lectura) lo exige el endpoint, no el sidebar.
      return { ...grupo, disponible: sesion?.puede_ver_modulo_3 ?? true };
    }
    return grupo;
  });
  // Un grupo SIN items (Panel, Configuración, ...) con disponible:false se muestra atenuado
  // ("Próximamente" — todavía no existe). Un grupo CON items sin permiso de módulo se oculta
  // directo: no es "no construido todavía", es "no te corresponde verlo".
  const gruposVisibles = gruposConGate.filter((grupo) => grupo.items.length === 0 || grupo.disponible);

  return (
    <div className="app-shell">
      <aside className="app-shell-aside">
        <strong className="app-shell-wordmark">Kairos</strong>
        <nav className="app-shell-nav">
          {gruposVisibles.map((grupo) => {
            const Icono = grupo.icono;

            if (grupo.items.length === 0) {
              return (
                <div key={grupo.label} className="nav-item-plano" aria-disabled={!grupo.disponible}>
                  <Icono size={18} aria-hidden="true" />
                  {grupo.label}
                </div>
              );
            }

            const abierto = gruposAbiertos.has(grupo.label);
            const grupoActivo = grupo.items.some(
              (item) => item.disponible && rutaActual.startsWith(item.href),
            );
            const ChevronIcono = abierto ? ChevronDown : ChevronRight;

            return (
              <div className="nav-grupo" key={grupo.label}>
                <button
                  type="button"
                  className={`nav-grupo-titulo${grupoActivo ? " nav-grupo-titulo--activo" : ""}`}
                  onClick={() => alternarGrupo(grupo.label)}
                  aria-expanded={abierto}
                >
                  <Icono size={18} aria-hidden="true" />
                  {grupo.label}
                  <ChevronIcono size={16} aria-hidden="true" />
                </button>
                {abierto && (
                  <div className="nav-subitems">
                    {grupo.items.map((item) => {
                      if (!item.disponible) {
                        return (
                          <div
                            key={item.label}
                            className="nav-subitem nav-subitem--atenuado"
                            aria-disabled="true"
                          >
                            {item.label}
                            <span className="etiqueta-proximamente">Próximamente</span>
                          </div>
                        );
                      }
                      const activo = rutaActual.startsWith(item.href);
                      return (
                        <a
                          key={item.href}
                          href={item.href}
                          className={`nav-subitem${activo ? " nav-subitem--activo" : ""}`}
                        >
                          {item.label}
                        </a>
                      );
                    })}
                  </div>
                )}
              </div>
            );
          })}
        </nav>
        <div className="app-shell-footer">
          {correoUsuario && <p className="app-shell-correo">{correoUsuario}</p>}
          <button type="button" onClick={cerrarSesion} className="boton-cerrar-sesion">
            <LogOut size={16} aria-hidden="true" />
            Cerrar sesión
          </button>
        </div>
      </aside>
      <main className="app-shell-main">{children}</main>
    </div>
  );
}
