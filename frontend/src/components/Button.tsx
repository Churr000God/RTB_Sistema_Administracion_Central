import type { AnchorHTMLAttributes, ButtonHTMLAttributes, ReactNode } from "react";
import { Loader2, type LucideIcon } from "lucide-react";

type PropsComunes = {
  variante?: "primario" | "plano";
  icono?: LucideIcon;
  posicionIcono?: "izquierda" | "derecha";
  tamanoIcono?: number;
  children: ReactNode;
};

type PropsBoton = PropsComunes &
  Omit<ButtonHTMLAttributes<HTMLButtonElement>, "type"> & {
    href?: undefined;
    type?: "button" | "submit" | "reset";
    // Estado "en curso" de una acción que dispara un fetch (guardar/otorgar/desactivar/...) —
    // deshabilita el botón de verdad (no sólo visualmente, evita el doble submit real) y
    // reemplaza el ícono por el spinner que ya se usa en toda la app (Loader2 + .icono-girando)
    // en vez de dejar el botón sin ningún feedback mientras espera la respuesta.
    cargando?: boolean;
    textoCargando?: ReactNode;
  };

type PropsEnlace = PropsComunes &
  AnchorHTMLAttributes<HTMLAnchorElement> & {
    href: string;
  };

type Props = PropsBoton | PropsEnlace;

// Envuelve las clases Kairos ya existentes (.boton-con-icono / .boton-primario) — no define
// estilos nuevos. Polimórfico entre <button> y <a href> porque las pantallas de Estructura
// Organizacional usan ambos indistintamente para la misma clase visual (alta vs. navegación).
export function Button(props: Props) {
  const {
    variante = "plano",
    icono: Icono,
    posicionIcono = "derecha",
    tamanoIcono = 16,
    className,
    children,
    ...resto
  } = props;

  const clases = ["boton-con-icono", variante === "primario" ? "boton-primario" : "", className]
    .filter(Boolean)
    .join(" ");

  const contenido = (
    <>
      {Icono && posicionIcono === "izquierda" && <Icono size={tamanoIcono} aria-hidden="true" />}
      {children}
      {Icono && posicionIcono === "derecha" && <Icono size={tamanoIcono} aria-hidden="true" />}
    </>
  );

  if (props.href !== undefined) {
    const { href, ...restoEnlace } = resto as Omit<PropsEnlace, keyof PropsComunes | "className">;
    return (
      <a href={href} className={clases} {...restoEnlace}>
        {contenido}
      </a>
    );
  }

  const { type, cargando, textoCargando, disabled, ...restoBoton } = resto as Omit<
    PropsBoton,
    keyof PropsComunes | "className"
  >;
  const spinner = <Loader2 size={tamanoIcono} className="icono-girando" aria-hidden="true" />;
  const contenidoBoton = cargando ? (
    <>
      {posicionIcono === "izquierda" && spinner}
      {textoCargando ?? children}
      {posicionIcono === "derecha" && spinner}
    </>
  ) : (
    contenido
  );
  return (
    <button type={type ?? "button"} className={clases} disabled={cargando || disabled} {...restoBoton}>
      {contenidoBoton}
    </button>
  );
}
