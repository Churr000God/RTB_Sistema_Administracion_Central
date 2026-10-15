import { useEffect, useState, type ReactNode } from "react";
import {
  BarChart3,
  Building2,
  CalendarClock,
  ChevronDown,
  AlertCircle,
  ChevronRight,
  Clock,
  Fingerprint,
  Home,
  LogOut,
  Settings,
  ShieldCheck,
  SlidersHorizontal,
  Users,
  type LucideIcon,
} from "lucide-react";

import { supabase } from "../lib/supabaseClient";
import { registrarErrorAuth } from "../lib/erroresAuth";
import { useSesion } from "../lib/useSesion";

type NavItem = { label: string; href: string; disponible: boolean };

// `disponible` (a nivel de grupo y de item) es el punto de enganche del gate de permisos.
// El de "Personas y Usuarios" y "Estructura organizacional" ya se deriva en tiempo real de
// `sesion.puede_ver_modulo_1`/`puede_ver_modulo_2` (ver `gruposConGate` más abajo) — el valor
// puesto acá abajo es sólo el default mientras la sesión no cargó o falló (fail-open). Los
// items DENTRO de cada grupo siguen fijos: no hay granularidad más fina que "el módulo
// completo" todavía.
type NavGroup = {
  label: string;
  icono: LucideIcon;
  disponible: boolean;
  items: NavItem[];
  // Grupo de un solo enlace (sin subitems), p. ej. «Inicio».
  href?: string;
};

const NAV_GROUPS: NavGroup[] = [
  // Siempre disponible para toda persona con sesión verificada: es el destino por defecto al entrar.
  { label: "Inicio", icono: Home, disponible: true, items: [], href: "/inicio" },
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
  {
    label: "Terminales",
    icono: Fingerprint,
    disponible: true,
    items: [
      { label: "Terminales", href: "/tiempo/terminales", disponible: true },
      { label: "Anomalías", href: "/tiempo/terminales/anomalias", disponible: true },
      { label: "Configuración", href: "/tiempo/terminales/configuracion", disponible: true },
    ],
  },
  { label: "Configuración", icono: Settings, disponible: false, items: [] },
];

type Props = { children: ReactNode };

export function AppShell({ children }: Props) {
  const rutaActual = typeof window !== "undefined" ? window.location.pathname : "";
  const [correoUsuario, setCorreoUsuario] = useState<string | null>(null);
  const { sesion, cargando, error, reintentar } = useSesion();
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

  // Guard de sesión (tres estados: cargando / error / cargada). LoginPage ya chequea /api/sesion al
  // loguearse, pero eso no cubre a alguien que ya tenía una sesión bloqueada y navega/recarga directo a una
  // ruta interna (AppShell envuelve todas). YA NO es fail-open: si /api/sesion falla (red, 5xx, tiempo
  // agotado, tras los reintentos automáticos) no se abre nada, se muestra un error con «Reintentar» y no se
  // monta ninguna pantalla de módulo. La RLS de Postgres sigue siendo el control real; esto evita mostrar
  // todo a una persona cuya sesión no se pudo verificar.
  const sesionNoAutenticada = error?.status === 401;
  const accesoDenegado = sesion !== null && !sesion.acceso_permitido;

  useEffect(() => {
    if (sesionNoAutenticada) {
      // Sin sesión válida: al login.
      window.location.href = "/";
      return;
    }
    if (!sesion || sesion.acceso_permitido) return;
    // Una vez confirmado que NO hay acceso el redirect tiene que pasar sí o sí: que signOut() falle no
    // puede dejar a la persona en una ruta interna rota (signOut ya limpia localStorage).
    let vivo = true;
    (async () => {
      try {
        await supabase.auth.signOut();
      } catch (errorSignOut) {
        registrarErrorAuth("AppShell.signOut", errorSignOut);
      }
      if (vivo) window.location.href = `/cuenta-suspendida?motivo=${sesion.motivo_bloqueo ?? "suspension"}`;
    })();
    return () => {
      vivo = false;
    };
  }, [sesion, sesionNoAutenticada]);

  async function cerrarSesion() {
    await supabase.auth.signOut();
    window.location.href = "/";
  }

  // Mientras no hay respuesta definitiva (o se está redirigiendo al login / a la cuenta suspendida) no se
  // monta nada.
  if ((cargando && !error) || sesionNoAutenticada || accesoDenegado) {
    return (
      <div className="app-shell-cargando">
        <p>Verificando acceso…</p>
      </div>
    );
  }

  // La sesión no se pudo verificar (tras los reintentos automáticos): se muestra el marco SIN menú de
  // módulos y sin montar la pantalla pedida.
  if (error || !sesion) {
    return (
      <div className="app-shell">
        <aside className="app-shell-aside">
          <strong className="app-shell-wordmark">
            <img src="/logo-rtb-compacto.png" alt="" aria-hidden="true" className="app-shell-logo" />
            RTB
          </strong>
          <nav className="app-shell-nav" aria-label="Menú no disponible" />
          <div className="app-shell-footer">
            {correoUsuario && <p className="app-shell-correo">{correoUsuario}</p>}
            <button type="button" onClick={cerrarSesion} className="boton-cerrar-sesion">
              <LogOut size={16} aria-hidden="true" />
              Cerrar sesión
            </button>
          </div>
        </aside>
        <main className="app-shell-main">
          <div className="contenedor-pagina">
            <div className="tarjeta-error" role="alert">
              <strong>
                <AlertCircle size={16} aria-hidden="true" />
                No pudimos verificar tu acceso
              </strong>
              <p>
                El servicio no respondió como se esperaba. Revisa tu conexión e inténtalo de nuevo; si sigue
                fallando, avisa a Sistemas.
              </p>
              <button type="button" className="boton-con-icono" onClick={reintentar}>
                Reintentar
              </button>
            </div>
          </div>
        </main>
      </div>
    );
  }

  // Gate de los grupos con módulo. Aquí la sesión ya está cargada y verificada: una bandera ausente o
  // false oculta el grupo (fail-closed). La RLS del backend sigue siendo el control real; esto es UI.
  const gruposConGate = NAV_GROUPS.map((grupo) => {
    if (grupo.label === "Personas y Usuarios") {
      return { ...grupo, disponible: sesion.puede_ver_modulo_1 === true };
    }
    if (grupo.label === "Estructura organizacional") {
      return { ...grupo, disponible: sesion.puede_ver_modulo_2 === true };
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
      return { ...grupo, disponible: sesion.puede_ver_modulo_3 === true };
    }
    if (grupo.label === "Terminales") {
      // puede_ver_terminales = terminal_usuario_lectura|edicion (terminal_config_edicion sola NO
      // lo abre, decisión del usuario).
      return { ...grupo, disponible: sesion.puede_ver_terminales === true };
    }
    return grupo;
  });
  // Un grupo SIN items (Configuración, ...) con disponible:false se muestra atenuado
  // ("Próximamente" — todavía no existe). Un grupo CON items sin permiso de módulo se oculta
  // directo: no es "no construido todavía", es "no te corresponde verlo".
  const gruposVisibles = gruposConGate.filter((grupo) => grupo.items.length === 0 || grupo.disponible);

  return (
    <div className="app-shell">
      <aside className="app-shell-aside">
        <strong className="app-shell-wordmark">
          <img src="/logo-rtb-compacto.png" alt="" aria-hidden="true" className="app-shell-logo" />
          RTB
        </strong>
        <nav className="app-shell-nav">
          {gruposVisibles.map((grupo) => {
            const Icono = grupo.icono;

            if (grupo.items.length === 0 && grupo.href) {
              const activoInicio = rutaActual === grupo.href;
              return (
                <a
                  key={grupo.label}
                  href={grupo.href}
                  className={`nav-item-plano nav-item-plano--enlace${activoInicio ? " nav-item-plano--activo" : ""}`}
                  aria-current={activoInicio ? "page" : undefined}
                >
                  <Icono size={18} aria-hidden="true" />
                  {grupo.label}
                </a>
              );
            }

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
                      // Con rutas anidadas (/tiempo/terminales y /tiempo/terminales/configuracion)
                      // sólo queda activo el item más específico.
                      const hermanoMasEspecifico = grupo.items.some(
                        (otro) =>
                          otro !== item &&
                          otro.disponible &&
                          otro.href.length > item.href.length &&
                          otro.href.startsWith(item.href) &&
                          rutaActual.startsWith(otro.href),
                      );
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
                      const activo = rutaActual.startsWith(item.href) && !hermanoMasEspecifico;
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
