import { Loader2 } from "lucide-react";

type DiaSemana = "lunes" | "martes" | "miercoles" | "jueves" | "viernes" | "sabado" | "domingo";

const DIAS_SEMANA: { valor: DiaSemana; etiqueta: string }[] = [
  { valor: "lunes", etiqueta: "Lun" },
  { valor: "martes", etiqueta: "Mar" },
  { valor: "miercoles", etiqueta: "Mié" },
  { valor: "jueves", etiqueta: "Jue" },
  { valor: "viernes", etiqueta: "Vie" },
  { valor: "sabado", etiqueta: "Sáb" },
  { valor: "domingo", etiqueta: "Dom" },
];

const ETIQUETA_TIPO_JORNADA: Record<string, string> = {
  normal: "Normal",
  flexible: "Flexible",
  de_confianza: "De confianza",
};

export type PatronDia = {
  dia_semana: DiaSemana;
  hora_entrada: string;
  hora_salida: string;
  minutos_comida: number;
};

export type JornadaVigente = {
  tipo_jornada: string;
  vigente_desde: string;
  horas_semanales_calculadas: number | null;
  patron_semanal: PatronDia[];
};

export type EstadoJornadaVigente = "cargando" | "listo" | "sin_jornada" | "sin_permiso";

type Props = {
  estado: EstadoJornadaVigente;
  jornada: JornadaVigente | null;
};

function formatearFecha(fecha?: string | null): string {
  if (!fecha) return "—";
  const valor = fecha.includes("T") ? new Date(fecha) : new Date(`${fecha}T00:00:00`);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" });
}

function formatearHora(hora: string): string {
  // hora_entrada/hora_salida llegan "HH:MM:SS" (time de Postgres) — sólo interesa HH:MM.
  return hora.slice(0, 5);
}

// Cuerpo de la tarjeta "Jornada asignada" -- extraído de FichaPersonaPage para reusarlo también
// en la fila expandible de AsignarJornadaPage (SCJ-PRA-01, mockup B elegido). No incluye el
// encabezado (título + link Asignar/Renovar): cada consumidor lo arma distinto (FichaPersonaPage
// lo envuelve en .tarjeta-resumen con su propio link a esta pantalla; AsignarJornadaPage lo
// embebe crudo dentro de una fila de tabla, que ya tiene su propio botón Asignar/Renovar).
export function DetalleJornadaAsignada({ estado, jornada }: Props) {
  if (estado === "cargando") {
    return (
      <p className="boton-con-icono">
        <Loader2 size={16} className="icono-girando" aria-hidden="true" />
        Cargando jornada…
      </p>
    );
  }

  if (estado === "sin_permiso") {
    return <p>No se pudo cargar la jornada.</p>;
  }

  if (estado === "sin_jornada" || !jornada) {
    return <p>Sin jornada vigente asignada.</p>;
  }

  return (
    <>
      <p className="meta-ficha">
        <span className="insignia insignia--neutra">
          {ETIQUETA_TIPO_JORNADA[jornada.tipo_jornada] ?? jornada.tipo_jornada}
        </span>{" "}
        vigente desde {formatearFecha(jornada.vigente_desde)}
        {jornada.horas_semanales_calculadas != null &&
          ` · ${jornada.horas_semanales_calculadas.toFixed(1)} h/semana`}
      </p>
      <div className="calendario-semanal">
        {DIAS_SEMANA.map(({ valor, etiqueta }) => {
          const dia = jornada.patron_semanal.find((p) => p.dia_semana === valor);
          return (
            <div
              key={valor}
              className={`dia-calendario ${dia ? "dia-calendario--trabaja" : "dia-calendario--libre"}`}
            >
              <span className="nombre-dia">{etiqueta}</span>
              {dia ? (
                <>
                  <span className="horario-dia">
                    {formatearHora(dia.hora_entrada)}–{formatearHora(dia.hora_salida)}
                  </span>
                  {dia.minutos_comida > 0 && (
                    <span className="comida-dia">{dia.minutos_comida} min comida</span>
                  )}
                </>
              ) : (
                <span className="horario-dia">Libre</span>
              )}
            </div>
          );
        })}
      </div>
    </>
  );
}
