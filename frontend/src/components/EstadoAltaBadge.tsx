import { CheckCircle2, Clock, Fingerprint, type LucideIcon } from "lucide-react";

import { Badge } from "./Badge";
import { ETIQUETA_ESTADO_ALTA, type EstadoAlta } from "../lib/terminales";

const VARIANTE: Record<EstadoAlta, "aviso" | "info" | "exito" | "neutra"> = {
  pendiente_alta: "aviso",
  esperando_huella: "info",
  activo: "exito",
  pendiente_baja: "aviso",
  baja: "neutra",
};

const ICONO: Partial<Record<EstadoAlta, LucideIcon>> = {
  pendiente_alta: Clock,
  esperando_huella: Fingerprint,
  activo: CheckCircle2,
  pendiente_baja: Clock,
};

// Los 5 estados se distinguen por icono + texto + color (nunca sólo color).
export function EstadoAltaBadge({ estado }: { estado: EstadoAlta }) {
  const Icono = ICONO[estado];
  return (
    <Badge variante={VARIANTE[estado]} className="estado-alta">
      {Icono && <Icono size={12} aria-hidden="true" />}
      {ETIQUETA_ESTADO_ALTA[estado]}
    </Badge>
  );
}
