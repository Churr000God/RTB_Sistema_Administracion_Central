from app.config import parse_frontend_urls


def test_parse_frontend_urls_un_solo_origen():
    assert parse_frontend_urls("http://localhost:5173") == ["http://localhost:5173"]


def test_parse_frontend_urls_varios_origenes_separados_por_coma():
    assert parse_frontend_urls("http://localhost:5173,http://100.71.242.4:5173") == [
        "http://localhost:5173",
        "http://100.71.242.4:5173",
    ]


def test_parse_frontend_urls_recorta_espacios_alrededor_de_cada_origen():
    assert parse_frontend_urls("http://localhost:5173 , http://100.71.242.4:5173") == [
        "http://localhost:5173",
        "http://100.71.242.4:5173",
    ]


def test_parse_frontend_urls_descarta_entradas_vacias():
    assert parse_frontend_urls("http://localhost:5173,,") == ["http://localhost:5173"]
