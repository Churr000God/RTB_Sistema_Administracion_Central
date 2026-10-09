"""SCJ-DEC-12 §1, §7, §10 (corte 1): autenticación de la terminal (llave opaca `scjt_…`), canal
HTTPS obligatorio, IP confiable, backoff por IP y logging seguro. Todo con mocks del cliente de
Supabase -- NUNCA contra la base real. El endpoint /api/terminal/latido sólo es el vehículo para
ejercitar la dependencia `get_terminal_actual`."""

import hashlib
import logging
import threading
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from _mocks_supabase import rpc_con_firma_real
from app import terminal_auth
from app.config import Settings, get_settings
from app.deps import get_service_client
from app.main import app

LLAVE = "scjt_" + "A" * 43
HASH_LLAVE = hashlib.sha256(LLAVE.encode()).hexdigest()
IP_PI = "198.51.100.7"
IP_PROXY = "10.0.0.2"
TERMINAL_ID = 7

AUTENTICADA = {
    "terminal_id": TERMINAL_ID,
    "serie": "TERM-FICTICIA-01",
    "credencial_id": 3,
    "ip_cambio": False,
}
LATIDO_OK = {
    "hora_servidor": "2026-10-06T15:00:00+00:00",
    "desfase_reloj_seg": 0,
    "ultima_secuencia_recibida": 10,
}


def _settings(**cambios) -> Settings:
    base = {
        "supabase_url": "http://supabase.invalido",
        "supabase_anon_key": "anon-ficticia",
        "supabase_service_role_key": "service-ficticia",
    }
    base.update(cambios)
    return Settings(**base)


def _db(autenticar=AUTENTICADA, latido=LATIDO_OK):
    """Mock del cliente service_role: `rpc(nombre, params)` devuelve datos distintos por nombre."""
    db = MagicMock()
    db.postgrest.schema.return_value.rpc = rpc_con_firma_real()
    respuestas = {"fn_terminal_autenticar": autenticar, "fn_terminal_latido": latido}

    def rpc(nombre, params):
        constructor = MagicMock()
        constructor.execute.return_value.data = respuestas[nombre]
        return constructor

    db.postgrest.schema.return_value.rpc.side_effect = rpc
    return db


def _llamadas_rpc(db):
    return db.postgrest.schema.return_value.rpc.call_args_list


def _cliente(db=None, settings=None, base_url="https://testserver", ip=IP_PI):
    db = db if db is not None else _db()
    app.dependency_overrides[get_service_client] = lambda: db
    app.dependency_overrides[get_settings] = lambda: settings or _settings()
    cliente = TestClient(app, base_url=base_url, client=(ip, 50000), raise_server_exceptions=False)
    return cliente, db


def _latido(cliente, llave=LLAVE, esquema="Bearer", headers=None, cuerpo=None):
    cabeceras = dict(headers or {})
    if llave is not None:
        cabeceras["Authorization"] = f"{esquema} {llave}"
    return cliente.post("/api/terminal/latido", json=cuerpo or {}, headers=cabeceras)


# --- formato de la llave: 401 sin tocar la base ------------------------------------------------


def test_sin_authorization_da_401_sin_llamar_a_la_base():
    cliente, db = _cliente()
    r = _latido(cliente, llave=None)
    assert r.status_code == 401
    assert r.headers["WWW-Authenticate"] == "Bearer"
    db.postgrest.schema.assert_not_called()


def test_esquema_distinto_de_bearer_da_401_sin_llamar_a_la_base():
    cliente, db = _cliente()
    r = _latido(cliente, esquema="Basic")
    assert r.status_code == 401
    db.postgrest.schema.assert_not_called()


@pytest.mark.parametrize(
    "llave",
    [
        "",
        "scjt_corta",
        "scjt_" + "A" * 42,
        "scjt_" + "A" * 44,
        "otro_" + "A" * 43,
        "SCJT_" + "A" * 43,
        "scjt_" + "A" * 42 + "!",
        "scjt_" + "A" * 42 + " ",
        "scjt_" + "ñ" * 43,
    ],
)
def test_llave_mal_formada_da_401_sin_llamar_a_la_base(llave):
    cliente, db = _cliente()
    if llave.isascii():
        r = _latido(cliente, llave=llave)
    else:  # httpx sólo acepta ASCII en str; se manda como bytes
        r = cliente.post(
            "/api/terminal/latido",
            json={},
            headers={"Authorization": b"Bearer " + llave.encode("utf-8")},
        )
    assert r.status_code == 401
    db.postgrest.schema.assert_not_called()


def test_el_mensaje_401_no_distingue_el_motivo():
    cliente_a, _ = _cliente()
    sin_header = _latido(cliente_a, llave=None).json()
    mal_formada = _latido(cliente_a, llave="scjt_corta").json()
    cliente_b, _ = _cliente(db=_db(autenticar=None))
    desconocida_o_revocada = _latido(cliente_b).json()
    assert sin_header == mal_formada == desconocida_o_revocada


# --- consulta a la base ------------------------------------------------------------------------


def test_llave_desconocida_revocada_o_terminal_inactiva_da_401():
    """El RPC devuelve NULL en los tres casos (no se distinguen)."""
    cliente, db = _cliente(db=_db(autenticar=None))
    r = _latido(cliente)
    assert r.status_code == 401
    assert r.headers["WWW-Authenticate"] == "Bearer"


def test_llave_valida_llama_al_rpc_con_el_hash_y_la_ip_y_no_con_la_llave():
    cliente, db = _cliente()
    r = _latido(cliente)
    assert r.status_code == 200
    primera = _llamadas_rpc(db)[0]
    assert primera.args[0] == "fn_terminal_autenticar"
    parametros = primera.args[1]
    assert parametros == {"p_hash": HASH_LLAVE, "p_ip": IP_PI}
    assert LLAVE not in repr(_llamadas_rpc(db))
    db.postgrest.schema.assert_called_with("tiempo")


def test_el_latido_recibe_el_id_de_terminal_de_la_credencial():
    cliente, db = _cliente()
    _latido(cliente)
    segunda = _llamadas_rpc(db)[1]
    assert segunda.args[0] == "fn_terminal_latido"
    assert segunda.args[1]["p_terminal_id"] == TERMINAL_ID


# --- canal HTTPS (falla cerrada) ----------------------------------------------------------------


def test_http_plano_se_rechaza_por_defecto_sin_llamar_a_la_base():
    cliente, db = _cliente(base_url="http://testserver")
    r = _latido(cliente)
    assert r.status_code == 403
    db.postgrest.schema.assert_not_called()


def test_requiere_https_es_true_por_defecto():
    assert _settings().terminal_requiere_https is True


def test_http_se_acepta_si_terminal_requiere_https_es_false():
    cliente, _ = _cliente(
        base_url="http://testserver", settings=_settings(terminal_requiere_https=False)
    )
    assert _latido(cliente).status_code == 200


def test_x_forwarded_proto_falsificado_sin_proxy_de_confianza_se_rechaza():
    cliente, db = _cliente(base_url="http://testserver")
    r = _latido(cliente, headers={"X-Forwarded-Proto": "https"})
    assert r.status_code == 403
    db.postgrest.schema.assert_not_called()


def test_x_forwarded_proto_https_de_un_proxy_de_confianza_se_acepta():
    cliente, _ = _cliente(
        base_url="http://testserver",
        settings=_settings(terminal_proxies_confianza=IP_PROXY),
        ip=IP_PROXY,
    )
    assert _latido(cliente, headers={"X-Forwarded-Proto": "https"}).status_code == 200


def test_proxy_de_confianza_pero_sin_x_forwarded_proto_falla_cerrado():
    cliente, _ = _cliente(
        base_url="http://testserver",
        settings=_settings(terminal_proxies_confianza=IP_PROXY),
        ip=IP_PROXY,
    )
    assert _latido(cliente).status_code == 403


def test_proxy_de_confianza_con_proto_http_se_rechaza():
    cliente, _ = _cliente(
        base_url="https://testserver",
        settings=_settings(terminal_proxies_confianza=IP_PROXY),
        ip=IP_PROXY,
    )
    assert _latido(cliente, headers={"X-Forwarded-Proto": "http"}).status_code == 403


def test_cadena_de_protos_se_evalua_por_el_ultimo_valor_del_proxy_de_confianza():
    """Un cliente puede anteponer 'https'; vale lo que agregó el proxy (el último)."""
    cliente, _ = _cliente(
        base_url="http://testserver",
        settings=_settings(terminal_proxies_confianza=IP_PROXY),
        ip=IP_PROXY,
    )
    assert _latido(cliente, headers={"X-Forwarded-Proto": "https, http"}).status_code == 403


def test_proxies_de_confianza_admite_cidr():
    cliente, _ = _cliente(
        base_url="http://testserver",
        settings=_settings(terminal_proxies_confianza="192.0.2.0/24, 10.0.0.0/8"),
        ip="10.9.9.9",
    )
    assert _latido(cliente, headers={"X-Forwarded-Proto": "https"}).status_code == 200


def test_entradas_invalidas_en_proxies_de_confianza_se_ignoran_sin_confiar_en_nadie():
    cliente, _ = _cliente(
        base_url="http://testserver",
        settings=_settings(terminal_proxies_confianza="no-es-una-ip, ,"),
    )
    assert _latido(cliente, headers={"X-Forwarded-Proto": "https"}).status_code == 403


def test_hsts_en_toda_respuesta_de_api_terminal():
    cliente, _ = _cliente()
    ok = _latido(cliente)
    mal = _latido(cliente, llave=None)
    for r in (ok, mal):
        assert "max-age=" in r.headers["Strict-Transport-Security"]


def test_hsts_tambien_cuando_se_rechaza_por_http():
    cliente, _ = _cliente(base_url="http://testserver")
    r = _latido(cliente)
    assert r.status_code == 403
    assert "max-age=" in r.headers["Strict-Transport-Security"]


def test_hsts_no_se_agrega_fuera_de_api_terminal():
    cliente, _ = _cliente()
    r = cliente.get("/salud")  # una ruta que SÍ existe (no un 404)
    assert r.status_code == 200
    assert "Strict-Transport-Security" not in r.headers


def test_hsts_dura_un_ano_y_sin_include_subdomains():
    cliente, _ = _cliente()
    valor = _latido(cliente).headers["Strict-Transport-Security"]
    assert valor == "max-age=31536000"
    assert "includeSubDomains" not in valor


# --- IP del cliente ------------------------------------------------------------------------------


def test_sin_proxy_de_confianza_x_forwarded_for_se_ignora():
    cliente, db = _cliente()
    _latido(cliente, headers={"X-Forwarded-For": "203.0.113.50"})
    assert _llamadas_rpc(db)[0].args[1]["p_ip"] == IP_PI


def test_con_proxy_de_confianza_se_toma_la_ultima_ip_no_confiable_de_x_forwarded_for():
    cliente, db = _cliente(
        settings=_settings(terminal_proxies_confianza=IP_PROXY),
        ip=IP_PROXY,
    )
    # el cliente falsifica la primera; el proxy agregó la real (203.0.113.9); la última es otro proxy
    _latido(
        cliente,
        headers={
            "X-Forwarded-For": f"1.2.3.4, 203.0.113.9, {IP_PROXY}",
            "X-Forwarded-Proto": "https",
        },
    )
    assert _llamadas_rpc(db)[0].args[1]["p_ip"] == "203.0.113.9"


def test_x_forwarded_for_basura_de_un_proxy_de_confianza_cae_a_la_ip_del_par():
    cliente, db = _cliente(
        settings=_settings(terminal_proxies_confianza=IP_PROXY),
        ip=IP_PROXY,
    )
    _latido(cliente, headers={"X-Forwarded-For": "no-es-ip", "X-Forwarded-Proto": "https"})
    assert _llamadas_rpc(db)[0].args[1]["p_ip"] == IP_PROXY


# --- backoff por IP --------------------------------------------------------------------------------


def _config_backoff(**extra):
    base = {"terminal_max_fallos_por_ip": 3, "terminal_bloqueo_base_seg": 60}
    base.update(extra)
    return _settings(**base)


def _reloj_falso(monkeypatch, inicio=1000.0):
    reloj = {"t": inicio}
    monkeypatch.setattr(terminal_auth.limitador, "reloj", lambda: reloj["t"])
    return reloj


def test_tras_n_401_consecutivos_la_ip_recibe_429_aun_con_llave_valida():
    db = _db(autenticar=None)
    cliente, _ = _cliente(db=db, settings=_config_backoff())
    for _ in range(3):
        assert _latido(cliente).status_code == 401
    r = _latido(cliente)
    assert r.status_code == 429
    assert int(r.headers["Retry-After"]) >= 1
    # aun con una llave válida: bloqueada por IP, no por llave
    app.dependency_overrides[get_service_client] = lambda: _db()
    assert _latido(cliente).status_code == 429


def test_el_429_lleva_retry_after_y_hsts():
    cliente, _ = _cliente(db=_db(autenticar=None), settings=_config_backoff())
    for _ in range(3):
        _latido(cliente)
    r = _latido(cliente)
    assert r.status_code == 429
    assert r.headers["Retry-After"].isdigit()
    assert r.headers["Strict-Transport-Security"] == "max-age=31536000"


def test_el_bloqueo_es_por_ip_no_por_llave_ni_terminal():
    cliente, _ = _cliente(db=_db(autenticar=None), settings=_config_backoff())
    for _ in range(3):
        _latido(cliente)
    otro, _ = _cliente(db=_db(), settings=_config_backoff(), ip="198.51.100.99")
    assert _latido(otro).status_code == 200


def test_los_fallos_de_formato_tambien_cuentan_para_el_backoff():
    cliente, _ = _cliente(settings=_config_backoff())
    for _ in range(3):
        assert _latido(cliente, llave="scjt_corta").status_code == 401
    assert _latido(cliente).status_code == 429


def test_un_exito_reinicia_la_cuenta_de_fallos_consecutivos():
    malo, _ = _cliente(db=_db(autenticar=None), settings=_config_backoff())
    _latido(malo)
    _latido(malo)
    assert terminal_auth.limitador.fallos_consecutivos(IP_PI) == 2
    bueno, _ = _cliente(db=_db(), settings=_config_backoff())
    assert _latido(bueno).status_code == 200
    assert terminal_auth.limitador.fallos_consecutivos(IP_PI) == 0


def test_un_fallo_de_la_base_no_cuenta_como_credencial_invalida():
    db = MagicMock()
    db.postgrest.schema.return_value.rpc.return_value.execute.side_effect = RuntimeError("caída")
    cliente, _ = _cliente(db=db, settings=_config_backoff())
    for _ in range(5):
        assert _latido(cliente).status_code == 503
    assert terminal_auth.limitador.fallos_consecutivos(IP_PI) == 0


def test_el_https_rechazado_no_cuenta_para_el_backoff():
    cliente, _ = _cliente(base_url="http://testserver", settings=_config_backoff())
    for _ in range(6):
        assert _latido(cliente).status_code == 403
    assert terminal_auth.limitador.fallos_consecutivos(IP_PI) == 0


def test_el_bloqueo_se_levanta_cuando_vence(monkeypatch):
    reloj = _reloj_falso(monkeypatch)
    cliente, _ = _cliente(db=_db(autenticar=None), settings=_config_backoff())
    for _ in range(3):
        _latido(cliente)
    assert _latido(cliente).status_code == 429
    reloj["t"] += 61
    assert _latido(cliente).status_code == 401


def test_el_bloqueo_crece_con_la_reincidencia(monkeypatch):
    reloj = _reloj_falso(monkeypatch)
    cliente, _ = _cliente(db=_db(autenticar=None), settings=_config_backoff())
    for _ in range(3):
        _latido(cliente)
    primera = int(_latido(cliente).headers["Retry-After"])
    reloj["t"] += primera + 1
    for _ in range(3):
        _latido(cliente)
    segunda = int(_latido(cliente).headers["Retry-After"])
    assert segunda > primera


def test_el_bloqueo_nunca_pasa_de_una_hora(monkeypatch):
    """Con max_fallos=1 cada fallo es una reincidencia: 60, 120, … el tope es 3600 s."""
    reloj = _reloj_falso(monkeypatch)
    cliente, _ = _cliente(
        db=_db(autenticar=None), settings=_config_backoff(terminal_max_fallos_por_ip=1)
    )
    esperas = []
    for _ in range(12):
        assert _latido(cliente).status_code == 401  # el fallo que dispara el bloqueo
        espera = int(_latido(cliente).headers["Retry-After"])
        esperas.append(espera)
        reloj["t"] += espera + 1
    assert max(esperas) <= 3600
    assert esperas[-1] == 3600  # llegó al tope y se quedó ahí
    assert esperas == sorted(esperas)


def test_los_fallos_dejan_de_acumularse_al_pasar_la_ventana(monkeypatch):
    """2 fallos, pasa más de la ventana, 1 fallo más: la cuenta se reinicia (1, no 3) -> sin 429."""
    reloj = _reloj_falso(monkeypatch)
    cliente, _ = _cliente(db=_db(autenticar=None), settings=_config_backoff())
    _latido(cliente)
    _latido(cliente)
    reloj["t"] += 301  # ventana por defecto: 300 s
    assert _latido(cliente).status_code == 401
    assert terminal_auth.limitador.fallos_consecutivos(IP_PI) == 1
    assert _latido(cliente).status_code == 401  # 2.º de la racha nueva: todavía sin bloqueo


# --- IP "buena": exención del 429 por IP compartida (M1) ---------------------------------------------


def test_una_ip_con_un_exito_previo_no_recibe_429_aunque_acumule_fallos():
    bueno, _ = _cliente(db=_db(), settings=_config_backoff())
    assert _latido(bueno).status_code == 200
    malo, _ = _cliente(db=_db(autenticar=None), settings=_config_backoff())
    for _ in range(8):
        assert _latido(malo).status_code == 401  # nunca 429: la IP es 'buena'
    assert terminal_auth.limitador.es_ip_buena(IP_PI)


def test_los_fallos_de_una_ip_buena_se_siguen_contando_y_registrando(caplog):
    bueno, _ = _cliente(db=_db(), settings=_config_backoff())
    _latido(bueno)
    malo, _ = _cliente(db=_db(autenticar=None), settings=_config_backoff())
    with caplog.at_level(logging.WARNING):
        for _ in range(4):
            _latido(malo)
    assert terminal_auth.limitador.fallos_consecutivos(IP_PI) in (1, 2, 3)  # sigue contando
    assert any("401" in x.getMessage() or "bloqueada" in x.getMessage() for x in caplog.records)


def test_la_exencion_de_ip_buena_vence_a_las_24_horas(monkeypatch):
    reloj = _reloj_falso(monkeypatch)
    bueno, _ = _cliente(db=_db(), settings=_config_backoff())
    _latido(bueno)
    reloj["t"] += 86_400 + 1
    assert not terminal_auth.limitador.es_ip_buena(IP_PI)
    malo, _ = _cliente(db=_db(autenticar=None), settings=_config_backoff())
    for _ in range(3):
        _latido(malo)
    assert _latido(malo).status_code == 429


def test_las_ips_buenas_son_a_lo_mas_64_y_se_expulsa_la_mas_vieja():
    lim = terminal_auth.LimitadorFallos()
    for i in range(70):
        lim.exito(f"203.0.113.{i}")
    assert not lim.es_ip_buena("203.0.113.0")
    assert lim.es_ip_buena("203.0.113.69")
    assert sum(lim.es_ip_buena(f"203.0.113.{i}") for i in range(70)) == 64


# --- IPv6 --------------------------------------------------------------------------------------------


def test_clave_ip_agrupa_ipv6_por_slash_64_e_ipv4_por_direccion():
    clave = terminal_auth.clave_ip
    assert clave("2001:db8:1:2::a") == clave("2001:db8:1:2:ffff::b")
    assert clave("2001:db8:1:2::a") != clave("2001:db8:1:3::a")
    assert clave("203.0.113.5") == "203.0.113.5"
    assert clave("::ffff:203.0.113.5") == "203.0.113.5"
    assert clave("no-es-ip") == "no-es-ip"


def test_el_bloqueo_ipv6_cubre_todo_el_slash_64():
    db = _db(autenticar=None)
    uno, _ = _cliente(db=db, settings=_config_backoff(), ip="2001:db8:1:2::a")
    for _ in range(3):
        _latido(uno)
    mismo_64, _ = _cliente(db=db, settings=_config_backoff(), ip="2001:db8:1:2:ffff::7")
    assert _latido(mismo_64).status_code == 429
    otro_64, _ = _cliente(db=db, settings=_config_backoff(), ip="2001:db8:1:3::a")
    assert _latido(otro_64).status_code == 401


def test_par_ipv6_en_cidr_de_confianza_y_xff_ipv6():
    cliente, db = _cliente(
        settings=_settings(terminal_proxies_confianza="2001:db8:aaaa::/48"),
        ip="2001:db8:aaaa::1",
    )
    _latido(
        cliente,
        headers={
            "X-Forwarded-For": "1.2.3.4, 2001:db8:bbbb::5, 2001:db8:aaaa::1",
            "X-Forwarded-Proto": "https",
        },
    )
    assert _llamadas_rpc(db)[0].args[1]["p_ip"] == "2001:db8:bbbb::5"


def test_una_red_ipv4_de_confianza_no_confia_en_un_par_ipv6():
    cliente, _ = _cliente(
        base_url="http://testserver",
        settings=_settings(terminal_proxies_confianza="10.0.0.0/8"),
        ip="::ffff:10.0.0.1",
    )
    # el par es IPv6 (mapeada): no coincide con una red IPv4 -> no se honra X-Forwarded-Proto
    assert _latido(cliente, headers={"X-Forwarded-Proto": "https"}).status_code == 403


# --- X-Forwarded-For raro con proxy de confianza -------------------------------------------------------


def test_xff_mixto_con_un_valor_basura_cae_a_la_ip_del_par():
    cliente, db = _cliente(settings=_settings(terminal_proxies_confianza=IP_PROXY), ip=IP_PROXY)
    _latido(cliente, headers={"X-Forwarded-For": "1.2.3.4, basura", "X-Forwarded-Proto": "https"})
    assert _llamadas_rpc(db)[0].args[1]["p_ip"] == IP_PROXY


def test_xff_vacio_con_proxy_de_confianza_usa_la_ip_del_par():
    cliente, db = _cliente(settings=_settings(terminal_proxies_confianza=IP_PROXY), ip=IP_PROXY)
    _latido(cliente, headers={"X-Forwarded-For": "", "X-Forwarded-Proto": "https"})
    assert _llamadas_rpc(db)[0].args[1]["p_ip"] == IP_PROXY


def test_xff_formado_solo_por_proxies_de_confianza_usa_la_ip_del_par():
    cliente, db = _cliente(
        settings=_settings(terminal_proxies_confianza="10.0.0.0/8"), ip="10.0.0.2"
    )
    _latido(cliente, headers={"X-Forwarded-For": "10.0.0.7, 10.0.0.8", "X-Forwarded-Proto": "https"})
    assert _llamadas_rpc(db)[0].args[1]["p_ip"] == "10.0.0.2"


def test_sin_request_client_la_ip_es_desconocida():
    from types import SimpleNamespace

    request = SimpleNamespace(client=None, headers={}, url=SimpleNamespace(scheme="https"))
    assert terminal_auth.ip_cliente(request, _settings()) == "desconocida"


# --- el limitador en sí --------------------------------------------------------------------------------


def test_el_limitador_acota_su_memoria_y_expulsa_en_lotes_hasta_el_80_por_ciento():
    lim = terminal_auth.LimitadorFallos(max_entradas=50)
    for i in range(500):
        lim.fallo(f"203.0.{i // 250}.{i % 250}", 3, 300, 60)
        assert len(lim) <= 50
    assert len(lim) <= 50
    # la expulsión es en lotes: tras exceder, baja a 40 (80 % de 50) y vuelve a crecer
    lim2 = terminal_auth.LimitadorFallos(max_entradas=50)
    for i in range(51):
        lim2.fallo(f"203.0.113.{i}", 3, 300, 60)
    assert len(lim2) == 40
    # la IP más antigua fue la expulsada, no la última
    assert lim2.fallos_consecutivos("203.0.113.0") == 0
    assert lim2.fallos_consecutivos("203.0.113.50") == 1


def test_los_fallos_concurrentes_de_la_misma_ip_son_coherentes():
    lim = terminal_auth.LimitadorFallos()
    errores = []

    def tarea():
        try:
            for _ in range(20):
                lim.fallo("203.0.113.5", 100_000, 300, 60)
        except Exception as error:  # pragma: no cover - sólo si falla la sincronización
            errores.append(error)

    hilos = [threading.Thread(target=tarea) for _ in range(50)]
    for hilo in hilos:
        hilo.start()
    for hilo in hilos:
        hilo.join()
    assert not errores
    assert lim.fallos_consecutivos("203.0.113.5") == 50 * 20


def test_los_fallos_concurrentes_que_disparan_bloqueos_no_pierden_consistencia():
    lim = terminal_auth.LimitadorFallos()

    def tarea():
        for _ in range(20):
            lim.fallo("203.0.113.6", 10, 300, 60)

    hilos = [threading.Thread(target=tarea) for _ in range(50)]
    for hilo in hilos:
        hilo.start()
    for hilo in hilos:
        hilo.join()
    assert 0 <= lim.fallos_consecutivos("203.0.113.6") < 10
    assert lim.segundos_bloqueado("203.0.113.6") > 0
    assert len(lim) == 1


# --- poco ruido en el log ---------------------------------------------------------------------------------


def test_los_401_repetidos_y_los_429_no_llenan_el_log(caplog):
    cliente, _ = _cliente(
        db=_db(autenticar=None), settings=_config_backoff(terminal_max_fallos_por_ip=5)
    )
    with caplog.at_level(logging.DEBUG):
        for _ in range(5):
            assert _latido(cliente).status_code == 401
        for _ in range(6):
            assert _latido(cliente).status_code == 429
    avisos = [x for x in caplog.records if x.levelno == logging.WARNING]
    # primer 401 de la racha + el que dispara el bloqueo + el primer 429 del bloqueo
    assert len(avisos) == 3
    assert len([x for x in caplog.records if x.levelno == logging.DEBUG and "terminal" in x.getMessage()]) >= 8


def test_el_log_de_un_bloqueo_menciona_la_ip_y_la_duracion(caplog):
    cliente, _ = _cliente(db=_db(autenticar=None), settings=_config_backoff())
    with caplog.at_level(logging.WARNING):
        for _ in range(3):
            _latido(cliente)
    assert any(IP_PI in x.getMessage() and "bloqueada" in x.getMessage() for x in caplog.records)


# --- fallos de la base ---------------------------------------------------------------------------


def test_42501_en_la_autenticacion_da_503_generico_y_log_error(caplog):
    db = MagicMock()
    db.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "42501", "message": "permission denied for function secreto-interno-777"}
    )
    cliente, _ = _cliente(db=db)
    with caplog.at_level(logging.DEBUG):
        r = _latido(cliente)
    assert r.status_code == 503
    assert "secreto-interno-777" not in r.text
    errores = [x for x in caplog.records if x.levelno >= logging.ERROR]
    assert errores, "un 42501 siempre debe dejar un ERROR en el log"
    assert "42501" in errores[0].getMessage()


def test_error_de_red_en_la_autenticacion_da_503_y_no_cuenta_como_fallo():
    db = MagicMock()
    db.postgrest.schema.return_value.rpc.return_value.execute.side_effect = ConnectionError("x")
    cliente, _ = _cliente(db=db)
    assert _latido(cliente).status_code == 503


def test_respuesta_del_rpc_con_forma_inesperada_da_503():
    cliente, _ = _cliente(db=_db(autenticar={"otra": "cosa"}))
    assert _latido(cliente).status_code == 503


# --- logging seguro (B1) ---------------------------------------------------------------------------


def _sin_secretos(texto: str):
    assert LLAVE not in texto
    assert LLAVE[5:] not in texto
    assert HASH_LLAVE not in texto
    assert "Bearer" not in texto
    assert "scjt_" not in texto


@pytest.mark.parametrize("escenario", ["valida", "desconocida", "formato", "base_caida", "42501", "cambio_ip"])
def test_la_llave_su_hash_y_authorization_nunca_aparecen_en_los_logs(escenario, caplog):
    if escenario == "valida":
        cliente, _ = _cliente()
    elif escenario == "desconocida":
        cliente, _ = _cliente(db=_db(autenticar=None))
    elif escenario == "formato":
        cliente, _ = _cliente()
    elif escenario == "base_caida":
        db = MagicMock()
        db.postgrest.schema.return_value.rpc.return_value.execute.side_effect = RuntimeError(
            f"fallo con {LLAVE} y {HASH_LLAVE}"
        )
        cliente, _ = _cliente(db=db)
    elif escenario == "42501":
        db = MagicMock()
        db.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
            {"code": "42501", "message": f"denegado {HASH_LLAVE}"}
        )
        cliente, _ = _cliente(db=db)
    else:
        cliente, _ = _cliente(db=_db(autenticar={**AUTENTICADA, "ip_cambio": True}))

    with caplog.at_level(logging.DEBUG):
        _latido(cliente, llave="scjt_corta" if escenario == "formato" else LLAVE)
    _sin_secretos(caplog.text)
    if escenario in {"valida"}:
        return
    assert caplog.records, "los escenarios de error deben dejar rastro (sin secretos)"


def test_cambio_de_ip_deja_un_warning_con_el_id_de_credencial(caplog):
    cliente, _ = _cliente(db=_db(autenticar={**AUTENTICADA, "ip_cambio": True}))
    with caplog.at_level(logging.WARNING):
        _latido(cliente)
    avisos = [x.getMessage() for x in caplog.records if x.levelno == logging.WARNING]
    assert any("credencial 3" in a and "IP" in a for a in avisos)


def test_el_handler_generico_de_main_no_serializa_la_excepcion():
    """Un error no previsto en el endpoint se responde como 500 genérico, sin str(exc)."""
    db = MagicMock()
    db.postgrest.schema.return_value.rpc = rpc_con_firma_real()

    def rpc(nombre, params):
        constructor = MagicMock()
        if nombre == "fn_terminal_autenticar":
            constructor.execute.return_value.data = AUTENTICADA
        else:
            constructor.execute.side_effect = APIError(
                {"code": "XX999", "message": "texto-crudo-con-id-interno-42"}
            )
        return constructor

    db.postgrest.schema.return_value.rpc.side_effect = rpc
    cliente, _ = _cliente(db=db)
    r = _latido(cliente)
    assert r.status_code == 500
    assert "texto-crudo-con-id-interno-42" not in r.text
    assert r.json() == {"detail": "Error interno del servidor."}


# --- piezas puras ------------------------------------------------------------------------------------


def test_hash_llave_es_sha256_hex_en_minusculas():
    assert terminal_auth.hash_llave(LLAVE) == HASH_LLAVE
    assert len(HASH_LLAVE) == 64


def test_generar_llave_cumple_el_formato():
    for _ in range(50):
        llave = terminal_auth.generar_llave()
        assert terminal_auth.FORMATO_LLAVE.fullmatch(llave)
        assert llave.startswith("scjt_") and len(llave) == 48
    assert terminal_auth.generar_llave() != terminal_auth.generar_llave()


# --- cuerpo inválido sin credencial: la autenticación manda (nunca 422) -------------------------------------


@pytest.mark.parametrize("cuerpo", [{"campo_inventado": 1}, {"version_pi": "x" * 5000}, {"marcas_pendientes": -9}])
def test_cuerpo_invalido_sin_credencial_da_401_nunca_422(cuerpo):
    cliente, db = _cliente()
    r = cliente.post("/api/terminal/latido", json=cuerpo)
    assert r.status_code == 401
    db.postgrest.schema.assert_not_called()


def test_cuerpo_invalido_por_http_plano_da_403_nunca_422():
    cliente, _ = _cliente(base_url="http://testserver")
    r = cliente.post("/api/terminal/latido", json={"campo_inventado": 1})
    assert r.status_code == 403


def test_cuerpo_invalido_con_llave_mal_formada_da_401_nunca_422():
    cliente, _ = _cliente()
    r = _latido(cliente, llave="scjt_corta", cuerpo={"campo_inventado": 1})
    assert r.status_code == 401


# --- el cliente de service_role no se crea si el canal no es seguro ---------------------------------------------


def test_sin_https_ni_siquiera_se_crea_el_cliente_service_role():
    creado = []

    def fabrica():
        creado.append(1)
        return _db()

    app.dependency_overrides[get_service_client] = fabrica
    app.dependency_overrides[get_settings] = lambda: _settings()
    cliente = TestClient(
        app, base_url="http://testserver", client=(IP_PI, 1), raise_server_exceptions=False
    )
    assert _latido(cliente).status_code == 403
    assert creado == []


# --- red de confianza /0 y avisos de despliegue ----------------------------------------------------------


@pytest.mark.parametrize("red", ["0.0.0.0/0", "::/0"])
def test_una_red_de_confianza_con_prefijo_0_se_ignora(red):
    cliente, _ = _cliente(
        base_url="http://testserver", settings=_settings(terminal_proxies_confianza=red)
    )
    assert _latido(cliente, headers={"X-Forwarded-Proto": "https"}).status_code == 403


def test_advertir_despliegue_avisa_si_forwarded_allow_ips_es_comodin(caplog):
    with caplog.at_level(logging.WARNING):
        avisos = terminal_auth.advertir_despliegue({"FORWARDED_ALLOW_IPS": "*"})
    assert len(avisos) == 1 and "FORWARDED_ALLOW_IPS" in avisos[0]
    assert any("FORWARDED_ALLOW_IPS" in x.getMessage() for x in caplog.records)


def test_advertir_despliegue_avisa_si_hay_un_comodin_entre_varias_ips():
    assert terminal_auth.advertir_despliegue({"FORWARDED_ALLOW_IPS": "10.0.0.1, *"})


def test_advertir_despliegue_avisa_de_proxies_de_confianza_que_abren_todo():
    avisos = terminal_auth.advertir_despliegue({"TERMINAL_PROXIES_CONFIANZA": "10.0.0.1, 0.0.0.0/0"})
    assert len(avisos) == 1 and "0.0.0.0/0" in avisos[0]


def test_advertir_despliegue_es_silencioso_con_una_configuracion_sana():
    assert terminal_auth.advertir_despliegue({}) == []
    assert terminal_auth.advertir_despliegue(
        {"FORWARDED_ALLOW_IPS": "10.0.0.2", "TERMINAL_PROXIES_CONFIANZA": "10.0.0.0/8"}
    ) == []


def test_main_llama_a_advertir_despliegue_al_arrancar():
    import inspect

    import app.main as principal

    assert "advertir_despliegue(os.environ)" in inspect.getsource(principal)


# --- Settings leyendo TERMINAL_* del entorno --------------------------------------------------------------------


def test_settings_lee_las_variables_terminal_del_entorno(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "http://x")
    monkeypatch.setenv("SUPABASE_ANON_KEY", "a")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "s")
    monkeypatch.setenv("TERMINAL_REQUIERE_HTTPS", "false")
    monkeypatch.setenv("TERMINAL_PROXIES_CONFIANZA", "10.0.0.0/8, 192.0.2.1")
    monkeypatch.setenv("TERMINAL_MAX_FALLOS_POR_IP", "4")
    monkeypatch.setenv("TERMINAL_VENTANA_FALLOS_SEG", "120")
    monkeypatch.setenv("TERMINAL_BLOQUEO_BASE_SEG", "30")
    ajustes = Settings(_env_file=None)
    assert ajustes.terminal_requiere_https is False
    assert ajustes.terminal_proxies_confianza == "10.0.0.0/8, 192.0.2.1"
    assert ajustes.terminal_max_fallos_por_ip == 4
    assert ajustes.terminal_ventana_fallos_seg == 120
    assert ajustes.terminal_bloqueo_base_seg == 30


def test_settings_valores_por_defecto_de_terminal(monkeypatch):
    for nombre in (
        "TERMINAL_REQUIERE_HTTPS",
        "TERMINAL_PROXIES_CONFIANZA",
        "TERMINAL_MAX_FALLOS_POR_IP",
        "TERMINAL_VENTANA_FALLOS_SEG",
        "TERMINAL_BLOQUEO_BASE_SEG",
    ):
        monkeypatch.delenv(nombre, raising=False)
    ajustes = _settings()
    assert ajustes.terminal_requiere_https is True
    assert ajustes.terminal_proxies_confianza == ""
    assert (
        ajustes.terminal_max_fallos_por_ip,
        ajustes.terminal_ventana_fallos_seg,
        ajustes.terminal_bloqueo_base_seg,
    ) == (10, 300, 60)
