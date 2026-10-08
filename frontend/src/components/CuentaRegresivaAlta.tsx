import { useEffect, useState } from "react";
import { AlertTriangle, Clock } from "lucide-react";

import { cuentaRegresiva } from "../lib/terminales";

const TICK_MS = 30_000;

// Tiempo restante de un alta en «Esperando huella». La hora límite (caduca_en) la calcula el
// servidor con la variable vigente; aquí sólo se cuenta hacia atrás, refrescando cada 30 s.
export function CuentaRegresivaAlta({ caducaEn }: { caducaEn: string }) {
  const [ahora, setAhora] = useState(() => new Date());

  useEffect(() => {
    setAhora(new Date());
    const id = setInterval(() => setAhora(new Date()), TICK_MS);
    return () => clearInterval(id);
  }, [caducaEn]);

  const cuenta = cuentaRegresiva(caducaEn, ahora);
  if (!cuenta) return null;
  const Icono = cuenta.urgente ? AlertTriangle : Clock;
  return (
    <div className={`cuenta-regresiva${cuenta.urgente ? " cuenta-regresiva--urgente" : ""}`}>
      <Icono size={12} aria-hidden="true" />
      <span>{cuenta.texto}</span>
    </div>
  );
}
