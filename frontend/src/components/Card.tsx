import type { FormHTMLAttributes, HTMLAttributes, ReactNode } from "react";

type PropsDiv = { as?: "div"; children: ReactNode } & HTMLAttributes<HTMLDivElement>;
type PropsForm = { as: "form"; children: ReactNode } & FormHTMLAttributes<HTMLFormElement>;

type Props = PropsDiv | PropsForm;

// Envuelve ".tarjeta-resumen" — la clase que ya funciona como tarjeta genérica en las
// pantallas de Estructura Organizacional (fondo blanco + radio-tarjeta + sombra-tarjeta).
// `as="form"` cubre el único caso real de tarjeta-formulario (ver FichaAreaPage).
export function Card({ as = "div", className, children, ...resto }: Props) {
  const clases = ["tarjeta-resumen", className].filter(Boolean).join(" ");

  if (as === "form") {
    return (
      <form className={clases} {...(resto as FormHTMLAttributes<HTMLFormElement>)}>
        {children}
      </form>
    );
  }

  return (
    <div className={clases} {...(resto as HTMLAttributes<HTMLDivElement>)}>
      {children}
    </div>
  );
}
