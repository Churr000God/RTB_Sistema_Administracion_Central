import { useEffect, useState } from "react";
import { Timer } from "lucide-react";

type Props = {
  id?: string;
};

function calcularRestante(): number {
  // Ancla al reloj Unix, como una app autenticadora — nunca decrementar un contador propio,
  // o el temporizador deriva cuando la pestaña se duerme y se despierta.
  return 30 - (Math.floor(Date.now() / 1000) % 30);
}

export function TemporizadorTotp({ id }: Props) {
  const [restante, setRestante] = useState(calcularRestante);

  useEffect(() => {
    const intervalo = setInterval(() => {
      setRestante(calcularRestante());
    }, 1000);
    return () => clearInterval(intervalo);
  }, []);

  const segundos = String(restante).padStart(2, "0");
  const porcentaje = (restante / 30) * 100;

  return (
    <div className="temporizador-totp">
      <div className="linea">
        <Timer size={14} aria-hidden="true" />
        <span>El código expira en</span>
        {/* aria-hidden: un número que cambia cada segundo dentro de un aria-live inundaría
            al lector de pantalla. La información real la da el texto estático de abajo,
            referenciado desde el casillero con aria-describedby. */}
        <span className="cuenta-regresiva" aria-hidden="true">
          00:{segundos}
        </span>
      </div>
      <div className="barra-progreso" aria-hidden="true">
        <div className="relleno" style={{ transform: `scaleX(${porcentaje / 100})` }} />
      </div>
      <p id={id}>El código cambia cada 30 segundos.</p>
    </div>
  );
}
