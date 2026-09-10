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

export function AuthLayout({ titulo, bajada, insignia, children }: Props) {
  const IconoInsignia = insignia?.icono;

  return (
    <div className="pantalla-auth">
      <aside className="panel-decorativo">
        <span className="wordmark">
          <span className="icono-reloj">
            <Clock size={18} color="white" aria-hidden="true" />
          </span>
          <strong>Kairos</strong>
        </span>
        <div className="bloque-mensaje">
          {insignia && IconoInsignia && (
            <span className="insignia insignia--clara">
              <IconoInsignia size={14} aria-hidden="true" />
              {insignia.texto}
            </span>
          )}
          <h1 className="titulo-panel">{titulo}</h1>
          <span className="regla-dorada" aria-hidden="true" />
          {bajada && <p className="bajada-panel">{bajada}</p>}
        </div>
        <small className="pie-panel">Distribuidora Central, S.A. de C.V. · v1.0</small>
      </aside>
      <main className="zona-formulario">
        <div className="tarjeta-auth">{children}</div>
      </main>
    </div>
  );
}
