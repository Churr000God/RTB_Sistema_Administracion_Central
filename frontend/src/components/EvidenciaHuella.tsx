import { CheckCircle2, Eye, Fingerprint } from "lucide-react";

import { Badge } from "./Badge";
import { etiquetaEvidencia, muestraEvidencia, type EstadoAlta, type HuellaEvidencia } from "../lib/terminales";

type Props = {
  alta: { estado: EstadoAlta; huella_evidencia: HuellaEvidencia | null; huellas_capturadas: number };
};

// Evidencia VIGENTE de la alta (campo de la alta, nunca la del último movimiento). Sin evidencia, o
// en un estado sin huella que mostrar, no pinta nada. «manual» va en tono aviso: es evidencia más
// débil que una marca real y debe distinguirse de un vistazo.
export function EvidenciaHuella({ alta }: Props) {
  if (!muestraEvidencia(alta.estado)) return null;
  const etiqueta = etiquetaEvidencia(alta.huella_evidencia, alta.huellas_capturadas);
  if (!etiqueta) return null;
  if (alta.huella_evidencia === "conteo") return <span className="num">{etiqueta}</span>;
  const Icono = alta.huella_evidencia === "manual" ? Eye : alta.huella_evidencia === "inferida" ? Fingerprint : CheckCircle2;
  return (
    <Badge variante={alta.huella_evidencia === "manual" ? "aviso" : "exito"} className="estado-alta">
      <Icono size={12} aria-hidden="true" />
      {etiqueta}
    </Badge>
  );
}
