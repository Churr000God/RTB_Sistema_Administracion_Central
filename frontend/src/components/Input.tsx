import type { InputHTMLAttributes, ReactNode } from "react";

type Props = {
  id: string;
  label: string;
  ayuda?: ReactNode;
  error?: string;
} & Omit<InputHTMLAttributes<HTMLInputElement>, "id">;

// Envuelve el patrón ".campo" (label + input + ayuda-campo/hint-campo) repetido en las
// pantallas de Estructura Organizacional. La única diferencia de comportamiento real frente
// a copiar el patrón a mano: input y ayuda/error quedan enlazados con aria-describedby, algo
// que ningún formulario de esa familia tenía todavía (sólo el <label> implícito).
export function Input({ id, label, ayuda, error, className, ...resto }: Props) {
  const idAyuda = `${id}-ayuda`;
  const idError = `${id}-error`;
  const describedBy = error ? idError : ayuda ? idAyuda : undefined;

  return (
    <div className="campo">
      <label htmlFor={id}>{label}</label>
      <input
        id={id}
        className={className}
        aria-describedby={describedBy}
        aria-invalid={error ? true : undefined}
        {...resto}
      />
      {error ? (
        <small className="hint-campo" id={idError} role="alert">
          {error}
        </small>
      ) : ayuda ? (
        <small className="ayuda-campo" id={idAyuda}>
          {ayuda}
        </small>
      ) : null}
    </div>
  );
}
