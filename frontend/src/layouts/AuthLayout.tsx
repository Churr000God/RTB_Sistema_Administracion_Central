import type { ReactNode } from "react";
import { Clock } from "lucide-react";

type Insignia = {
  icono: typeof Clock;
  texto: string;
};

type Props = {
  titulo: string;
  bajada: string;
  insignia?: Insignia;
  children: ReactNode;
};

function ReglaDorada() {
  return (
    <svg className="regla-dorada" viewBox="0 0 48 12" aria-hidden="true">
      <path d="M0 6 Q 12 0, 24 6 T 48 6" />
    </svg>
  );
}

export function AuthLayout({ titulo, bajada, insignia, children }: Props) {
  const IconoInsignia = insignia?.icono;

  return (
    <div className="pantalla-auth">
      <aside className="panel-decorativo">
        <div className="marca-hero">
          <img src="/logo-rtb.png" alt="Refacciones Tomás Badillo" className="logo-hero" />
          <span className="antetitulo-marca">Sistema de control de jornada</span>
          <p className="nombre-marca">Refacciones Tomás Badillo</p>
          <p className="legal-marca">S.A. de C.V.</p>
          <ReglaDorada />
        </div>
        <div className="bloque-mensaje">
          {insignia && IconoInsignia && (
            <span className="insignia insignia--clara">
              <IconoInsignia size={14} aria-hidden="true" />
              {insignia.texto}
            </span>
          )}
          <h1 className="titulo-panel">{titulo}</h1>
          {bajada && <p className="bajada-panel">{bajada}</p>}
        </div>
        <small className="pie-panel">Refacciones Tomás Badillo, S.A. de C.V. · v1.0</small>
      </aside>
      <main className="zona-formulario">
        <div className="tarjeta-auth">{children}</div>
      </main>
    </div>
  );
}
