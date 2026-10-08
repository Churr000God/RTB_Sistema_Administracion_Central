"""C1 del contrato de Terminales (Paquete 2): mapeo de errores SCJ11–SCJ17, es_administrador_generico y
banderas de /api/sesion. Mocks del cliente de Supabase -- NUNCA contra la base real."""

import logging
from unittest.mock import MagicMock

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app import errores
from app.deps import CallerIdentity, get_caller_identity, get_service_client
from app.errores import manejar_error_terminal_web, traducir_error_terminal_web
from app.main import app
from app.permisos import es_administrador_generico

CRUDO = "texto-crudo-con-id-interno-6613 (alta 42)"


def _error(code, hint=None):
    return APIError({"code": code, "hint": hint, "message": CRUDO, "details": CRUDO})


# --- mapeo de errores (texto LITERAL: es el contrato con el frontend) ---------------------------------------

CASOS = [
    ("SCJ11", "transicion_invalida", 409, "El movimiento no es válido para el estado actual del alta."),
    ("SCJ11", None, 409, "El movimiento no es válido para el estado actual del alta."),
    ("SCJ16", None, 409, "El texto de consentimiento cambió; vuelve a leerlo."),
    ("22023", None, 422, "Los datos enviados no son válidos."),
    ("22023", "otro", 422, "Los datos enviados no son válidos."),
    ("22023", "huellas_invalidas", 422, "Los datos enviados no son válidos."),
    ("22023", "retencion_invalida", 422, "Los datos enviados no son válidos."),
    ("22023", "lote_no_elegible", 409, "No se registró nada: algunas altas ya no son elegibles."),
    ("23503", None, 422, "Un dato relacionado no existe o no está sincronizado; avisa a Sistemas."),
    ("23505", None, 409, "Otro cambio ocurrió al mismo tiempo; recarga."),
    ("SCJ12", "alta_duplicada", 409, "La persona ya tiene un alta vigente en esta terminal."),
    ("SCJ12", "persona_no_activa", 422, "La persona no existe o no está activa."),
    ("SCJ12", "terminal_no_valida", 422, "La terminal no existe o no está activa."),
    ("SCJ13", "terminal_con_altas_vigentes", 409, "La terminal tiene altas vigentes; da de baja todas antes de desactivarla."),
    ("SCJ14", None, 409, "La credencial ya está revocada."),
    ("SCJ16", "consentimiento_desactualizado", 409, "El texto de consentimiento cambió; vuelve a leerlo."),
    ("SCJ16", "consentimiento_requerido", 422, "Falta la versión del texto de consentimiento."),
    ("SCJ16", "hint_nuevo", 409, "El texto de consentimiento cambió; vuelve a leerlo."),
    ("SCJ17", "clave_reservada", 403, "Esa variable se edita desde Terminales → Configuración."),
    ("22023", "texto_invalido", 422, "El texto debe tener entre 1 y 4 000 caracteres."),
    ("22023", "nota_invalida", 422, "El motivo del cambio no puede pasar de 200 caracteres."),
    ("22023", "lote_invalido", 422, "El lote debe traer entre 1 y 200 altas."),
    ("22023", "clave_no_editable", 404, "La variable no existe."),
    ("22023", "valor_invalido", 422, "El valor no es válido para esta variable."),
    ("SCJ02", None, 404, "No existe un parámetro activo con esa clave."),
    ("42501", "sin_permiso", 403, "No tienes permiso para esta acción."),
    ("22023", "motivo_invalido", 422, "El motivo es obligatorio."),
    ("SCJ15", "dia_no_revisado", 409, "El día todavía no está revisado: revísalo en vez de descartar la marca."),
]


@pytest.mark.parametrize("codigo,hint,estado,mensaje", CASOS)
def test_cada_error_se_traduce_a_su_estado_y_mensaje_fijo(codigo, hint, estado, mensaje):
    traduccion = traducir_error_terminal_web(_error(codigo, hint))
    assert isinstance(traduccion, HTTPException)
    assert traduccion.status_code == estado
    assert traduccion.detail == mensaje
    assert "6613" not in traduccion.detail and "alta 42" not in traduccion.detail


def test_valor_invalido_con_rango_arma_el_mensaje_en_el_backend_no_con_el_texto_de_la_base():
    traduccion = traducir_error_terminal_web(_error("22023", "valor_invalido"), rango=(4, 168))
    assert traduccion.detail == "El valor debe ser un entero entre 4 y 168."
    assert "6613" not in traduccion.detail


def test_scj12_con_hint_desconocido_no_se_traduce():
    assert traducir_error_terminal_web(_error("SCJ12", "hint_nuevo")) is None


@pytest.mark.parametrize("codigo,hint", [("XX000", None), (None, None), ("SCJ99", None)])
def test_lo_que_no_es_de_esta_familia_devuelve_none(codigo, hint):
    assert traducir_error_terminal_web(_error(codigo, hint)) is None


def test_42501_sin_hint_es_403_y_deja_error_en_el_log(caplog):
    with caplog.at_level(logging.ERROR):
        traduccion = traducir_error_terminal_web(_error("42501", None))
    assert traduccion.status_code == 403
    assert any(x.levelno >= logging.ERROR for x in caplog.records)
    assert "6613" not in caplog.text


def test_manejar_levanta_la_traduccion_y_relanza_lo_desconocido():
    with pytest.raises(HTTPException) as excinfo:
        manejar_error_terminal_web(_error("SCJ11"))
    assert excinfo.value.status_code == 409
    with pytest.raises(APIError):
        manejar_error_terminal_web(_error("XX000"))


def test_la_traduccion_no_encadena_el_error_original_en_la_respuesta():
    with pytest.raises(HTTPException) as excinfo:
        manejar_error_terminal_web(_error("SCJ11"))
    assert excinfo.value.__cause__ is None  # `from None`: el texto crudo no viaja encadenado


def test_los_codigos_que_cubre_la_tabla_del_contrato_estan_todos_mapeados():
    for codigo in ("SCJ11", "SCJ12", "SCJ13", "SCJ14", "SCJ15", "SCJ16", "SCJ17"):
        hint = {"SCJ12": "alta_duplicada", "SCJ15": "dia_no_revisado"}.get(codigo)
        assert traducir_error_terminal_web(_error(codigo, hint)) is not None, codigo


# --- es_administrador_generico -------------------------------------------------------------------------------------


from _mocks_supabase import db_por_nombre as _db  # noqa: E402
from _mocks_supabase import tabla as _tabla  # noqa: E402


def test_es_administrador_generico_true_si_algun_puesto_vigente_lo_es():
    puesto = _tabla([{"es_administrador_generico": False}, {"es_administrador_generico": True}])
    db = _db(asignacion=_tabla([{"puesto_id": "p1"}, {"puesto_id": "p2"}]), puesto=puesto)
    assert es_administrador_generico(db, "persona") is True
    puesto.in_.assert_called_once_with("id", ["p1", "p2"])


def test_es_administrador_generico_false_si_ninguno_lo_es():
    db = _db(asignacion=_tabla([{"puesto_id": "p1"}]), puesto=_tabla([{"es_administrador_generico": False}]))
    assert es_administrador_generico(db, "persona") is False


def test_es_administrador_generico_false_sin_puestos_vigentes_y_sin_consultar_puesto():
    puesto = _tabla([])
    db = _db(asignacion=_tabla([]), puesto=puesto)
    assert es_administrador_generico(db, "persona") is False
    puesto.execute.assert_not_called()


def test_es_administrador_generico_solo_mira_asignaciones_vigentes():
    asignacion = _tabla([{"puesto_id": "p1"}])
    es_administrador_generico(_db(asignacion=asignacion, puesto=_tabla([])), "persona-x")
    asignacion.eq.assert_called_with("persona_id", "persona-x")
    asignacion.is_.assert_called_with("vigente_hasta", "null")


# --- banderas de /api/sesion --------------------------------------------------------------------------------------

CALLER = CallerIdentity(auth_user_id="auth-ficticio", correo="x@example.com")


def _sesion(monkeypatch, permisos_concedidos, estado_persona="activo"):
    from app.routers import sesion

    consultados = []

    def tiene_permisos(db, persona_id, codigos):
        consultados.extend(codigos)
        return {codigo: codigo in permisos_concedidos for codigo in codigos}

    monkeypatch.setattr(sesion, "tiene_permisos", tiene_permisos)
    db = _db(
        usuario=_tabla([{"auth_user_id": "a", "nombre_usuario": "ana", "persona_id": "persona"}]),
        persona=_tabla([{"estado": estado_persona}]),
    )
    app.dependency_overrides[get_service_client] = lambda: db
    app.dependency_overrides[get_caller_identity] = lambda: CALLER
    r = TestClient(app).get("/api/sesion", headers={"Authorization": "Bearer t"})
    assert r.status_code == 200, r.text
    return r.json(), consultados


BANDERAS = ("puede_ver_terminales", "puede_editar_terminales", "puede_editar_config_terminales")


def _b(cuerpo):
    return tuple(cuerpo[k] for k in BANDERAS)


def test_sin_permisos_de_terminal_las_tres_banderas_son_false(monkeypatch):
    cuerpo, _ = _sesion(monkeypatch, set())
    assert _b(cuerpo) == (False, False, False)


def test_solo_lectura_ve_pero_no_edita(monkeypatch):
    cuerpo, _ = _sesion(monkeypatch, {"terminal_usuario_lectura"})
    assert _b(cuerpo) == (True, False, False)


def test_edicion_ve_y_edita_terminales_pero_no_la_configuracion(monkeypatch):
    cuerpo, _ = _sesion(monkeypatch, {"terminal_usuario_edicion"})
    assert _b(cuerpo) == (True, True, False)


def test_config_edicion_sola_no_ve_terminales_q5_decidido(monkeypatch):
    """Q5 (decidido por el usuario): terminal_config_edicion sola NO abre Terminales; sólo marca la bandera
    de configuración."""
    cuerpo, _ = _sesion(monkeypatch, {"terminal_config_edicion"})
    assert _b(cuerpo) == (False, False, True)


@pytest.mark.parametrize("codigo", ["terminal_usuario_lectura", "terminal_usuario_edicion"])
def test_lectura_o_edicion_de_altas_si_ve_terminales(monkeypatch, codigo):
    cuerpo, _ = _sesion(monkeypatch, {codigo})
    assert cuerpo["puede_ver_terminales"] is True


def test_ti_con_todo(monkeypatch):
    cuerpo, _ = _sesion(
        monkeypatch, {"terminal_usuario_lectura", "terminal_usuario_edicion", "terminal_config_edicion"}
    )
    assert _b(cuerpo) == (True, True, True)


def test_cuenta_bloqueada_tiene_las_tres_en_false_y_no_consulta_permisos(monkeypatch):
    cuerpo, consultados = _sesion(
        monkeypatch,
        {"terminal_usuario_lectura", "terminal_usuario_edicion", "terminal_config_edicion"},
        estado_persona="suspension",
    )
    assert cuerpo["acceso_permitido"] is False
    assert _b(cuerpo) == (False, False, False)
    assert consultados == []


def test_las_banderas_existentes_no_cambian(monkeypatch):
    cuerpo, _ = _sesion(monkeypatch, {"ver_modulo_3", "excepcion_dia_cerrado_descarte"})
    assert cuerpo["puede_ver_modulo_3"] is True
    assert cuerpo["puede_descartar_excepciones"] is True
    assert cuerpo["puede_ver_modulo_1"] is False




# --- contexto de 23505 / 23503 (asignación) y 22023 desconocido (ajustes de security y testing) ----------------------


def test_23505_y_23503_con_contexto_asignacion_dicen_lo_de_la_asignacion():
    unica = traducir_error_terminal_web(_error("23505"), contexto="asignacion")
    fk = traducir_error_terminal_web(_error("23503"), contexto="asignacion")
    assert (unica.status_code, unica.detail) == (409, "Otra asignación de esta persona ocurrió al mismo tiempo; recarga.")
    assert (fk.status_code, fk.detail) == (422, "La persona no está sincronizada en el esquema de tiempo; avisa a Sistemas.")


def test_sin_contexto_23505_y_23503_no_afirman_nada_de_asignaciones():
    for codigo in ("23505", "23503"):
        traduccion = traducir_error_terminal_web(_error(codigo))
        assert "asignación" not in traduccion.detail.lower()
        assert "persona" not in traduccion.detail.lower()


def test_el_contexto_solo_cambia_23505_y_23503():
    for codigo, hint in (("SCJ11", None), ("SCJ12", "alta_duplicada"), ("SCJ16", "consentimiento_desactualizado")):
        sin = traducir_error_terminal_web(_error(codigo, hint))
        con = traducir_error_terminal_web(_error(codigo, hint), contexto="asignacion")
        assert (sin.status_code, sin.detail) == (con.status_code, con.detail)


def test_manejar_pasa_el_contexto():
    with pytest.raises(HTTPException) as excinfo:
        manejar_error_terminal_web(_error("23505"), contexto="asignacion")
    assert excinfo.value.detail.startswith("Otra asignación")


def test_lote_no_elegible_no_relaya_el_detail_de_la_base():
    traduccion = traducir_error_terminal_web(_error("22023", "lote_no_elegible"))
    assert traduccion.status_code == 409
    assert "6613" not in traduccion.detail and "alta 42" not in traduccion.detail


def test_22023_motivo_invalido_sigue_delegando_al_helper_de_86():
    assert traducir_error_terminal_web(_error("22023", "motivo_invalido")).detail == "El motivo es obligatorio."


def test_22023_desconocido_ya_no_dice_motivo_obligatorio():
    for hint in (None, "otro", "huellas_invalidas"):
        assert "motivo" not in traducir_error_terminal_web(_error("22023", hint)).detail.lower()


# --- /api/sesion con tiene_permisos REAL y 88_ sin aplicar --------------------------------------------------------------


def test_sesion_real_con_puesto_vigente_pero_sin_permisos_ni_codigos_88_da_las_tres_false():
    """Tolerancia REAL a 88_ sin aplicar: el puesto vigente existe, puesto_permiso y permiso devuelven []."""
    db = _db(
        usuario=_tabla([{"auth_user_id": "a", "nombre_usuario": "ana", "persona_id": "persona"}]),
        persona=_tabla([{"estado": "activo"}]),
        asignacion=_tabla([{"puesto_id": "p1"}]),
        puesto_permiso=_tabla([]),
        permiso=_tabla([]),
        puesto=_tabla([]),
    )
    app.dependency_overrides[get_service_client] = lambda: db
    app.dependency_overrides[get_caller_identity] = lambda: CALLER
    r = TestClient(app).get("/api/sesion", headers={"Authorization": "Bearer t"})
    assert r.status_code == 200, r.text
    cuerpo = r.json()
    assert _b(cuerpo) == (False, False, False)
    assert cuerpo["puede_ver_modulo_1"] is False


def test_sesion_resuelve_los_permisos_con_consultas_fijas_no_con_una_por_codigo():
    """El rendimiento no se rompe: puesto_permiso se consulta UNA vez sin importar cuántos códigos."""
    pp = _tabla([{"puesto_id": "p1", "codigo": "terminal_usuario_edicion"}])
    db = _db(
        usuario=_tabla([{"auth_user_id": "a", "nombre_usuario": "ana", "persona_id": "persona"}]),
        persona=_tabla([{"estado": "activo"}]),
        asignacion=_tabla([{"puesto_id": "p1"}]),
        puesto_permiso=pp,
        permiso=_tabla([]),
    )
    app.dependency_overrides[get_service_client] = lambda: db
    app.dependency_overrides[get_caller_identity] = lambda: CALLER
    r = TestClient(app).get("/api/sesion", headers={"Authorization": "Bearer t"})
    assert _b(r.json()) == (True, True, False)
    assert pp.execute.call_count == 1
