import type { ReactNode } from "react";

import { AppShell } from "../layouts/AppShell";

type Props = { activa: "consentimiento" | "variables" | "huella"; children: ReactNode };

// Marco común de Configuración de terminales (consentimiento y variables). Se ve con la misma
// visibilidad del grupo Terminales; editar exige terminal_config_edicion (RH la ve en sólo lectura).
export function ConfiguracionTerminalesLayout({ activa, children }: Props) {
  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <a href="/tiempo/terminales">Terminales</a> / <strong>Configuración</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Configuración de terminales</h1>
            <p className="subtitulo-pagina">
              El texto de consentimiento biométrico y las variables del módulo se editan aquí. La pantalla la ve
              quien ve el grupo Terminales; editan sólo quienes tengan{" "}
              <span className="chip-permiso">terminal_config_edicion</span> (Gerente o Encargado de TI y Gerente
              General). RH la ve en sólo lectura.
            </p>
          </div>
        </div>
        <nav className="pestanas-config" aria-label="Secciones de configuración">
          <a
            href="/tiempo/terminales/configuracion"
            aria-current={activa === "consentimiento" ? "page" : undefined}
          >
            Texto de consentimiento
          </a>
          <a
            href="/tiempo/terminales/configuracion/variables"
            aria-current={activa === "variables" ? "page" : undefined}
          >
            Variables
          </a>
          <a
            href="/tiempo/terminales/configuracion/activacion-por-huella"
            aria-current={activa === "huella" ? "page" : undefined}
          >
            Activación por huella
          </a>
        </nav>
        {children}
      </div>
    </AppShell>
  );
}
