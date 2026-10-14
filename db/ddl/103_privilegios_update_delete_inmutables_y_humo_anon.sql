-- 103_privilegios_update_delete_inmutables_y_humo_anon.sql
-- Tercer corte de endurecimiento de privilegios (después de 100_ tiempo y 102_ personas): UPDATE/DELETE que ninguna ruta usa, y el último SELECT de anon.
-- Alcance autorizado por el usuario el 14-oct-2026 y aprobado por security; inventario por catálogo + lectura de funciones y backend, del 14-oct-2026 (sin tocar la base).
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 103_*.sql` (el archivo NO lleva BEGIN/COMMIT). Solo REVOKE: idempotente, sin DDL de objetos, sin policies, sin funciones.
--
-- QUÉ HACE
--   (a) REVOKE SELECT ON personas.permiso FROM anon. Era la única excepción de 102_ (humo del Data API, sección 9 del verificador: 200 con []). La sección 9 pasa a esperar 401 con
--       código 42501 («permission denied»), que sigue probando que el Data API responde y que anon NO lee nada.
--   (b1) REVOKE UPDATE, DELETE ON personas.bitacora_movimiento_persona FROM service_role. Su inmutabilidad la garantiza el trigger BEFORE UPDATE/DELETE (trg_bitacora_inmutable), que bloquea
--        incluso al dueño; 28_ ya había revocado esos privilegios en la hermana (bitacora_movimiento_puesto_permiso) y aquí faltó. Nada del backend ni de las funciones hace UPDATE/DELETE ahí
--        (solo INSERT; fn_bitacora_sincroniza_persona actualiza personas.persona, no la bitácora). Defensa en profundidad.
--   (b2) REVOKE UPDATE, DELETE FROM authenticated en: tiempo.aprobacion_ausencia, tiempo.clasificacion_de_tiempo, tiempo.corrida_batch, tiempo.dia_festivo, tiempo.tope_legal, tiempo.persona;
--        y REVOKE DELETE FROM authenticated en: tiempo.ausencia, tiempo.dia, tiempo.excepcion, tiempo.tramo. En todas, RLS ya anulaba el privilegio (ninguna policy de UPDATE/DELETE para
--        authenticated, o policy de UPDATE y ninguna de DELETE) y ninguna ruta del caller lo usa: el backend usa service_role para dia_festivo, tope_legal, corrida_batch y dia
--        (cierre_dia.py:270), y las funciones INVOKER que ejecuta authenticated (fn_ausencia_resolver, fn_dia_revisar, fn_correccion_recalcula_tramo, fn_jornada_*, fn_persona_actualizar_datos)
--        solo hacen UPDATE sobre ausencia, dia, excepcion, tramo, jornada_asignada, patron_semanal y personas.persona, que se CONSERVAN. Ninguna función hace DELETE sobre ausencia/dia/excepcion/tramo.
--        Revocar es higiene: no cambia el comportamiento (con RLS el UPDATE/DELETE ya afectaba 0 filas).
--   (b3) REVOKE DELETE ON tiempo.parametro FROM service_role. Ningún código lo usa: el backend solo LEE parametro (banco_alertas_magnitud.py, banco_antiguedad.py, alertas_horario.py,
--        dias_habiles.py, catalogo_terminal.py) y las vigencias se editan por RPC (fn_parametro_actualizar_valor, INVOKER, EXECUTE solo service_role, usa UPDATE/INSERT; fn_terminal_config_actualizar y
--        fn_parametro_inferir_escribe, DEFINER). UPDATE se CONSERVA (lo usa fn_parametro_actualizar_valor). Nota: el ensayo_97 (caso 84) ejercía un DELETE directo de service_role «auditado» como
--        residuo aceptado del 97_; con esta revocación ese vector queda cerrado (el trigger de auditoría conserva la operación DELETE para el dueño). Los ensayos 97/98 son históricos y ya aplicados.
--
-- LO QUE QUEDA FUERA (a propósito; con su razón; la siguiente pasada parte de aquí):
--   * tiempo.banco_de_horas, UPDATE y DELETE de authenticated: NO se revocan. fn_movimiento_de_saldo_actualiza_banco (trigger AFTER INSERT sobre movimiento_de_saldo) es SECURITY INVOKER y
--     hace UPDATE sobre banco_de_horas; lo dispara el RPC INVOKER fn_movimiento_de_saldo_manual_registrar con el caller (authenticated). No hay policy de UPDATE para authenticated sobre banco_de_horas:
--     hoy ese UPDATE ya filtraría 0 filas por RLS. Revocar el privilegio convertiría un no-op silencioso en un 42501 visible. HALLAZGO PARA BACKEND/SECURITY (tiempo.movimiento_de_saldo no tiene
--     filas, así que no se ha ejercido): confirmar si el trigger debería ser SECURITY DEFINER (con search_path) para que el movimiento manual actualice el saldo; decisión de diseño, no de este archivo.
--   * GRUPO E (service_role con UPDATE/DELETE en tiempo), tabla por tabla, razón y uso:
--       aprobacion_ausencia (U,D): sin uso (fn_ausencia_resolver solo INSERTa) -> excedente.
--       ausencia (U,D): U lo hace fn_ausencia_resolver (INVOKER, authenticated) y el trigger DEFINER fn_aprobacion_ausencia_actualiza_ausencia; service_role sin uso directo -> excedente.
--       banco_de_horas (U,D): U lo necesita el trigger INVOKER fn_movimiento_de_saldo_actualiza_banco cuando el batch corte_quincenal inserta movimientos con service_role; D sin uso -> D excedente.
--       clasificacion_de_tiempo (U,D): sin uso -> excedente.
--       tope_legal (U,D): U lo usa fn_tope_legal_crear_vigencia (INVOKER, solo service_role); D sin uso -> D excedente.
--       tramo (U,D): U por fn_correccion_recalcula_tramo (trigger INVOKER) y fn_dia_revisar (INVOKER, authenticated); D sin uso -> D excedente.
--       patron_semanal (U,D) y jornada_asignada (U,D): los usan solo las funciones fn_jornada_* (INVOKER, authenticated); service_role sin uso -> excedente, pero sus triggers de protección
--       (75_) ya cierran vigencias; se deja por la dependencia de los triggers.
--       excepcion (U,D): U por fn_dia_revisar (INVOKER, authenticated) y fn_correccion_recalcula_tramo (INVOKER trigger); D sin uso -> D excedente.
--       persona (tiempo, U,D): sin uso -> excedente.
--       dia (U): backend/app/batches/cierre_dia.py:270 (service_role); D sin uso. corrida_batch (U): backend/app/batches/_orquestacion.py:26,62,101 (service_role); D sin uso.
--       dia_festivo (D): backend/app/routers/dias_festivos.py:98 (service_role); U sin uso.
--     Esa pasada debe confirmar cada INVOKER/trigger con un ensayo antes de revocar (un trigger INVOKER que escribe como service_role necesita el privilegio).
--
-- Inventario de RLS: sin cambios (no se crea ni cambia ninguna policy).
--
-- REVERSA EXACTA: guardar ANTES de aplicar la salida de la consulta de reversa de 100_/102_ ejecutada para los dos esquemas (personas y tiempo):
--     SELECT format('GRANT %s ON %s %s TO %I;', string_agg(a.privilege_type, ', ' ORDER BY a.privilege_type),
--                   CASE WHEN c.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END, c.oid::regclass, r.rolname)
--     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--     CROSS JOIN LATERAL aclexplode(c.relacl) a JOIN pg_roles r ON r.oid = a.grantee
--     WHERE n.nspname IN ('personas','tiempo') AND c.relkind IN ('r','p','v','m','f','S') AND r.rolname IN ('anon','authenticated','service_role')
--     GROUP BY c.oid, c.relkind, r.rolname;
--   db/ensayos/ensayo_103.sql ejecuta este procedimiento dentro de su transacción y comprueba que la foto de privilegios queda idéntica a la previa.

-- (a) el último SELECT de anon en personas
REVOKE SELECT ON TABLE personas.permiso FROM anon;

-- (b1) bitácora inmutable de personas: la protección es el trigger, el privilegio sobra
REVOKE UPDATE, DELETE ON TABLE personas.bitacora_movimiento_persona FROM service_role;

-- (b2) authenticated: privilegios anulados por RLS que ninguna ruta del caller usa
REVOKE UPDATE, DELETE ON TABLE tiempo.aprobacion_ausencia FROM authenticated;
REVOKE UPDATE, DELETE ON TABLE tiempo.clasificacion_de_tiempo FROM authenticated;
REVOKE UPDATE, DELETE ON TABLE tiempo.corrida_batch FROM authenticated;
REVOKE UPDATE, DELETE ON TABLE tiempo.dia_festivo FROM authenticated;
REVOKE UPDATE, DELETE ON TABLE tiempo.tope_legal FROM authenticated;
REVOKE UPDATE, DELETE ON TABLE tiempo.persona FROM authenticated;
REVOKE DELETE ON TABLE tiempo.ausencia FROM authenticated;
REVOKE DELETE ON TABLE tiempo.dia FROM authenticated;
REVOKE DELETE ON TABLE tiempo.excepcion FROM authenticated;
REVOKE DELETE ON TABLE tiempo.tramo FROM authenticated;

-- (b3) parametro: las vigencias se editan por RPC; nadie borra filas
REVOKE DELETE ON TABLE tiempo.parametro FROM service_role;
