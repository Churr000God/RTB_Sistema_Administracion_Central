import { useEffect, useRef, type ChangeEvent, type ClipboardEvent, type KeyboardEvent } from "react";

type Props = {
  valor: string;
  onCambio: (valor: string) => void;
  longitud?: number;
  etiqueta: string;
  idBase: string;
  name: string;
  descripcionId?: string;
  invalido?: boolean;
  deshabilitado?: boolean;
  enfocarAlMontar?: boolean;
  onCompleto?: (valor: string) => void;
};

export function CasilleroCodigo({
  valor,
  onCambio,
  longitud = 6,
  etiqueta,
  idBase,
  name,
  descripcionId,
  invalido = false,
  deshabilitado = false,
  enfocarAlMontar = false,
  onCompleto,
}: Props) {
  const inputsRef = useRef<Array<HTMLInputElement | null>>([]);
  const longitudPreviaRef = useRef(valor.length);

  useEffect(() => {
    if (enfocarAlMontar) {
      inputsRef.current[0]?.focus();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (valor.length === longitud && longitudPreviaRef.current < longitud) {
      onCompleto?.(valor);
    }
    longitudPreviaRef.current = valor.length;
  }, [valor, longitud, onCompleto]);

  function celdasActuales(): string[] {
    return valor.padEnd(longitud, " ").slice(0, longitud).split("");
  }

  function establecerCeldas(celdas: string[]) {
    onCambio(celdas.join("").replace(/ +$/, ""));
  }

  function manejarCambio(indice: number, evento: ChangeEvent<HTMLInputElement>) {
    const entrada = evento.target.value.replace(/\D/g, "");
    const celdas = celdasActuales();
    if (!entrada) {
      celdas[indice] = " ";
      establecerCeldas(celdas);
      return;
    }
    celdas[indice] = entrada.slice(-1);
    establecerCeldas(celdas);
    if (indice < longitud - 1) {
      inputsRef.current[indice + 1]?.focus();
    }
  }

  function manejarTeclaAbajo(indice: number, evento: KeyboardEvent<HTMLInputElement>) {
    if (evento.key === "Backspace") {
      const celdas = celdasActuales();
      if (celdas[indice] !== " " && celdas[indice] !== "") {
        return; // deja que el onChange normal borre el dígito de esta celda
      }
      evento.preventDefault();
      if (indice > 0) {
        celdas[indice - 1] = " ";
        establecerCeldas(celdas);
        inputsRef.current[indice - 1]?.focus();
      }
      return;
    }
    if (evento.key === "ArrowLeft" && indice > 0) {
      evento.preventDefault();
      inputsRef.current[indice - 1]?.focus();
      return;
    }
    if (evento.key === "ArrowRight" && indice < longitud - 1) {
      evento.preventDefault();
      inputsRef.current[indice + 1]?.focus();
      return;
    }
    if (evento.key === "Home") {
      evento.preventDefault();
      inputsRef.current[0]?.focus();
      return;
    }
    if (evento.key === "End") {
      evento.preventDefault();
      inputsRef.current[longitud - 1]?.focus();
    }
  }

  function manejarPegado(evento: ClipboardEvent<HTMLInputElement>) {
    evento.preventDefault();
    const normalizado = evento.clipboardData.getData("text").replace(/\D/g, "").slice(0, longitud);
    if (!normalizado) return;
    onCambio(normalizado);
    inputsRef.current[Math.min(normalizado.length, longitud - 1)]?.focus();
  }

  const celdas = celdasActuales();

  return (
    <fieldset className={`casillero-codigo${invalido ? " invalido" : ""}`}>
      <legend className="etiqueta-casillero">{etiqueta}</legend>
      <div className="celdas">
        {celdas.map((digito, indice) => (
          <input
            key={indice}
            ref={(elemento) => {
              inputsRef.current[indice] = elemento;
            }}
            id={`${idBase}-${indice}`}
            type="text"
            inputMode="numeric"
            autoComplete={indice === 0 ? "one-time-code" : "off"}
            maxLength={1}
            value={digito === " " ? "" : digito}
            aria-label={`Dígito ${indice + 1} de ${longitud}`}
            aria-describedby={descripcionId}
            aria-invalid={invalido || undefined}
            disabled={deshabilitado}
            onChange={(evento) => manejarCambio(indice, evento)}
            onKeyDown={(evento) => manejarTeclaAbajo(indice, evento)}
            onFocus={(evento) => evento.target.select()}
            onPaste={manejarPegado}
          />
        ))}
      </div>
      <input type="hidden" name={name} value={valor} />
    </fieldset>
  );
}
