import { Lock } from "lucide-react";

// Estado «sin acceso» del módulo Terminales: se ve con terminal_usuario_lectura o _edicion
// (terminal_config_edicion sola no lo abre). Nombre del permiso como texto, nunca un enlace.
export function SinAccesoTerminales() {
  return (
    <div className="estado-vacio">
      <Lock size={40} aria-hidden="true" />
      <p>
        <strong>No tienes acceso a las terminales.</strong>
        <br />
        Esta pantalla es parte del grupo Terminales. Pídele a Recursos Humanos o a TI el permiso{" "}
        <span className="chip-permiso">terminal_usuario_lectura</span>.
      </p>
    </div>
  );
}
