import { createBrowserRouter } from "react-router-dom";

import { AltaAreaPage } from "./pages/AltaAreaPage";
import { AltaAsignacionPage } from "./pages/AltaAsignacionPage";
import { AltaDepartamentoPage } from "./pages/AltaDepartamentoPage";
import { AltaPersonaPage } from "./pages/AltaPersonaPage";
import { AltaPuestoPage } from "./pages/AltaPuestoPage";
import { AltaUsuarioPage } from "./pages/AltaUsuarioPage";
import { AsignacionesPage } from "./pages/AsignacionesPage";
import { AsignarJornadaPage } from "./pages/AsignarJornadaPage";
import { AlertasDeRetardoPage } from "./pages/AlertasDeRetardoPage";
import { BancoDeHorasPage } from "./pages/BancoDeHorasPage";
import { DiasFestivosPage } from "./pages/DiasFestivosPage";
import { ParametrosTopeLegalPage } from "./pages/ParametrosTopeLegalPage";
import { ParametrosSistemaPage } from "./pages/ParametrosSistemaPage";
import { BandejaAusenciasPage } from "./pages/BandejaAusenciasPage";
import { BitacoraAsignacionesPersonaPage } from "./pages/BitacoraAsignacionesPersonaPage";
import { BitacoraMovimientosPage } from "./pages/BitacoraMovimientosPage";
import { CambiarEstadoPage } from "./pages/CambiarEstadoPage";
import { CambiarPuestoAsignacionPage } from "./pages/CambiarPuestoAsignacionPage";
import { CapturaManualMarcaPage } from "./pages/CapturaManualMarcaPage";
import { ColaExcepcionesPage } from "./pages/ColaExcepcionesPage";
import { RegistroMarcasPage } from "./pages/RegistroMarcasPage";
import { CorregirMarcaPage } from "./pages/CorregirMarcaPage";
import { CompletarInvitacionPage } from "./pages/CompletarInvitacionPage";
import { Configurar2FAPage } from "./pages/Configurar2FAPage";
import { CuentaSuspendidaPage } from "./pages/CuentaSuspendidaPage";
import { DiasPage } from "./pages/DiasPage";
import { DirectorioAreasPage } from "./pages/DirectorioAreasPage";
import { DirectorioDepartamentosPage } from "./pages/DirectorioDepartamentosPage";
import { DirectorioPersonasPage } from "./pages/DirectorioPersonasPage";
import { DirectorioPuestosPage } from "./pages/DirectorioPuestosPage";
import { FichaAreaPage } from "./pages/FichaAreaPage";
import { FichaDepartamentoPage } from "./pages/FichaDepartamentoPage";
import { FichaPersonaPage } from "./pages/FichaPersonaPage";
import { FichaPuestoPage } from "./pages/FichaPuestoPage";
import { LoginPage } from "./pages/LoginPage";
import { OlvideContrasenaPage } from "./pages/OlvideContrasenaPage";
import { OtorgarPermisoPage } from "./pages/OtorgarPermisoPage";
import { PanelCorridasBatchPage } from "./pages/PanelCorridasBatchPage";
import { PermisosPage } from "./pages/PermisosPage";
import { RestablecerContrasenaPage } from "./pages/RestablecerContrasenaPage";
import { RevocarPermisoPage } from "./pages/RevocarPermisoPage";
import { TerminarAsignacionPage } from "./pages/TerminarAsignacionPage";
import { TramosPage } from "./pages/TramosPage";
import { VerificarTotpRoute } from "./pages/VerificarTotpRoute";

export const router = createBrowserRouter([
  { path: "/", element: <LoginPage /> },
  { path: "/cuenta-suspendida", element: <CuentaSuspendidaPage /> },
  { path: "/configurar-2fa", element: <Configurar2FAPage /> },
  { path: "/verificar-totp", element: <VerificarTotpRoute /> },
  { path: "/olvide-contrasena", element: <OlvideContrasenaPage /> },
  { path: "/restablecer-contrasena", element: <RestablecerContrasenaPage /> },
  { path: "/completar-invitacion", element: <CompletarInvitacionPage /> },
  { path: "/personas", element: <DirectorioPersonasPage /> },
  { path: "/personas/nueva", element: <AltaPersonaPage /> },
  { path: "/personas/:id", element: <FichaPersonaPage /> },
  { path: "/personas/:id/movimiento", element: <CambiarEstadoPage /> },
  { path: "/personas/:id/bitacora", element: <BitacoraMovimientosPage /> },
  { path: "/personas/:id/bitacora-asignaciones", element: <BitacoraAsignacionesPersonaPage /> },
  { path: "/usuarios/nuevo", element: <AltaUsuarioPage /> },
  { path: "/estructura/areas", element: <DirectorioAreasPage /> },
  { path: "/estructura/areas/nueva", element: <AltaAreaPage /> },
  { path: "/estructura/areas/:id", element: <FichaAreaPage /> },
  { path: "/estructura/departamentos", element: <DirectorioDepartamentosPage /> },
  { path: "/estructura/departamentos/nueva", element: <AltaDepartamentoPage /> },
  { path: "/estructura/departamentos/:id", element: <FichaDepartamentoPage /> },
  { path: "/estructura/puestos", element: <DirectorioPuestosPage /> },
  { path: "/estructura/puestos/nueva", element: <AltaPuestoPage /> },
  { path: "/estructura/puestos/:id", element: <FichaPuestoPage /> },
  { path: "/estructura/asignaciones", element: <AsignacionesPage /> },
  { path: "/estructura/asignaciones/nueva", element: <AltaAsignacionPage /> },
  { path: "/estructura/asignaciones/:id/terminar", element: <TerminarAsignacionPage /> },
  { path: "/estructura/asignaciones/:id/cambiar-puesto", element: <CambiarPuestoAsignacionPage /> },
  { path: "/estructura/permisos", element: <PermisosPage /> },
  { path: "/estructura/permisos/otorgar", element: <OtorgarPermisoPage /> },
  { path: "/estructura/permisos/:id/revocar", element: <RevocarPermisoPage /> },
  { path: "/tiempo/asignacion-jornada", element: <AsignarJornadaPage /> },
  { path: "/tiempo/corridas-batch", element: <PanelCorridasBatchPage /> },
  { path: "/tiempo/captura-manual", element: <CapturaManualMarcaPage /> },
  { path: "/tiempo/marcas", element: <RegistroMarcasPage /> },
  { path: "/tiempo/excepciones", element: <ColaExcepcionesPage /> },
  { path: "/tiempo/tramos", element: <TramosPage /> },
  { path: "/tiempo/dias", element: <DiasPage /> },
  { path: "/tiempo/excepciones/:id/corregir", element: <CorregirMarcaPage /> },
  { path: "/tiempo/ausencias", element: <BandejaAusenciasPage /> },
  { path: "/tiempo/banco-de-horas", element: <BancoDeHorasPage /> },
  { path: "/tiempo/alertas-retardo", element: <AlertasDeRetardoPage /> },
  { path: "/tiempo/parametros/tope-legal", element: <ParametrosTopeLegalPage /> },
  { path: "/tiempo/parametros/dias-festivos", element: <DiasFestivosPage /> },
  { path: "/tiempo/parametros/sistema", element: <ParametrosSistemaPage /> },
]);
