import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";

import { CasilleroCodigo } from "./CasilleroCodigo";

function Envoltorio({ onCompleto }: { onCompleto?: (valor: string) => void }) {
  const [valor, setValor] = useState("");
  return (
    <CasilleroCodigo
      valor={valor}
      onCambio={setValor}
      etiqueta="Código de verificación"
      idBase="totp"
      name="codigo"
      onCompleto={onCompleto}
    />
  );
}

describe("CasilleroCodigo", () => {
  it("auto-avanza el foco al escribir cada dígito", async () => {
    render(<Envoltorio />);
    await userEvent.click(screen.getByLabelText("Dígito 1 de 6"));
    await userEvent.keyboard("123456");

    for (let i = 0; i < 6; i++) {
      expect(screen.getByLabelText(`Dígito ${i + 1} de 6`)).toHaveValue(String(i + 1));
    }
  });

  it("Backspace en celda vacía retrocede y limpia la celda anterior", async () => {
    render(<Envoltorio />);
    await userEvent.click(screen.getByLabelText("Dígito 1 de 6"));
    await userEvent.keyboard("12");
    await userEvent.keyboard("{Backspace}");

    expect(screen.getByLabelText("Dígito 2 de 6")).toHaveValue("");
    expect(screen.getByLabelText("Dígito 2 de 6")).toHaveFocus();
  });

  it("normaliza el pegado, descartando lo que no sea dígito", async () => {
    render(<Envoltorio />);
    await userEvent.click(screen.getByLabelText("Dígito 1 de 6"));
    await userEvent.paste("ab12cd3456xyz");

    for (let i = 0; i < 6; i++) {
      expect(screen.getByLabelText(`Dígito ${i + 1} de 6`)).toHaveValue(String(i + 1));
    }
  });

  it("rechaza letras: la celda se queda vacía", async () => {
    render(<Envoltorio />);
    await userEvent.click(screen.getByLabelText("Dígito 1 de 6"));
    await userEvent.keyboard("a");

    expect(screen.getByLabelText("Dígito 1 de 6")).toHaveValue("");
  });

  it("dispara onCompleto una sola vez al llenar las 6 celdas", async () => {
    const onCompleto = vi.fn();
    render(<Envoltorio onCompleto={onCompleto} />);
    await userEvent.click(screen.getByLabelText("Dígito 1 de 6"));
    await userEvent.keyboard("123456");

    expect(onCompleto).toHaveBeenCalledTimes(1);
    expect(onCompleto).toHaveBeenCalledWith("123456");
  });

  it("el input oculto refleja el valor completo para FormData", async () => {
    const { container } = render(<Envoltorio />);
    await userEvent.click(screen.getByLabelText("Dígito 1 de 6"));
    await userEvent.keyboard("123");

    const oculto = container.querySelector('input[name="codigo"][type="hidden"]');
    expect(oculto).toHaveValue("123");
  });
});
