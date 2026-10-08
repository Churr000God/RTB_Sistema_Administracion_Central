import { useEffect, useId, useRef, type ReactNode } from "react";

type Props = {
  titulo: ReactNode;
  descripcion?: ReactNode;
  // true mientras hay un envío en curso: Escape se ignora (sin doble envío ni cierre a medias).
  bloqueado?: boolean;
  onCancelar: () => void;
  children: ReactNode;
};

// <dialog> nativo con showModal(): foco atrapado, Escape y ::backdrop. El padre decide cuándo
// desmontarlo; al desmontar se cierra el diálogo nativo para que el navegador devuelva el foco al
// botón que lo abrió.
export function Modal({ titulo, descripcion, bloqueado = false, onCancelar, children }: Props) {
  const ref = useRef<HTMLDialogElement>(null);
  const idTitulo = useId();
  const idDescripcion = useId();

  useEffect(() => {
    const dialogo = ref.current;
    if (!dialogo) return;
    if (!dialogo.open) dialogo.showModal();
    return () => {
      if (dialogo.open) dialogo.close();
    };
  }, []);

  return (
    <dialog
      ref={ref}
      className="modal"
      aria-labelledby={idTitulo}
      aria-describedby={descripcion ? idDescripcion : undefined}
      onCancel={(evento) => {
        evento.preventDefault();
        if (!bloqueado) onCancelar();
      }}
    >
      <h2 id={idTitulo}>{titulo}</h2>
      {descripcion && (
        <p className="modal__contexto" id={idDescripcion}>
          {descripcion}
        </p>
      )}
      {children}
    </dialog>
  );
}
