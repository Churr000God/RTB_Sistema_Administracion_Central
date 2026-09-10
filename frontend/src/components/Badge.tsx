import type { HTMLAttributes, ReactNode } from "react";

type VarianteInsignia = "clara" | "exito" | "neutra" | "aviso" | "peligro";
type VarianteEstado = "activo" | "suspension" | "baja_definitiva";

type PropsInsignia = {
  variante: VarianteInsignia;
  estado?: undefined;
  bloque?: boolean;
  children: ReactNode;
} & Omit<HTMLAttributes<HTMLSpanElement>, "children">;

type PropsEstado = {
  variante?: undefined;
  estado: VarianteEstado;
  bloque?: undefined;
  children: ReactNode;
} & Omit<HTMLAttributes<HTMLSpanElement>, "children">;

type Props = PropsInsignia | PropsEstado;

// Envuelve las dos familias de badge ya existentes en tokens.css: ".insignia--*" (mensajes de
// estado genéricos) y ".insignia-estado.*" (activo/suspensión/baja definitiva de una persona,
// área, departamento o puesto). No agrega variantes nuevas.
export function Badge({ variante, estado, bloque, className, children, ...resto }: Props) {
  const clases = estado
    ? ["insignia-estado", estado, className].filter(Boolean).join(" ")
    : ["insignia", `insignia--${variante}`, bloque ? "insignia--bloque" : "", className]
        .filter(Boolean)
        .join(" ");

  return (
    <span className={clases} {...resto}>
      {children}
    </span>
  );
}
