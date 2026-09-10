"""Pruebas directas de app/permisos.py (tiene_permiso/tiene_alguno/requiere_permiso) -- la
lógica de herencia jerárquica y edición-implica-lectura del gate real, sin pasar por HTTP.
Los 403 de cada router ya se cubren en su propio test_*.py (test_areas.py,
test_departamentos.py, test_puestos.py, test_asignaciones.py, test_permisos.py,
test_personas.py, test_usuarios.py, test_movimientos.py) -- acá sólo la lógica compartida.
"""

from unittest.mock import MagicMock

from app.permisos import tiene_alguno, tiene_permiso

PERSONA_ID = "persona-ficticia-gate-test"

ABUELO_ID = "puesto-ficticio-abuelo"
PADRE_ID = "puesto-ficticio-padre"
HIJO_ID = "puesto-ficticio-hijo-gate"

CODIGO_HEREDABLE = "permiso_ficticio_heredable"
CODIGO_NO_HEREDABLE = "permiso_ficticio_no_heredable"


def _arbol_tres_niveles():
    return [
        {"id": ABUELO_ID, "reporta_a_id": None},
        {"id": PADRE_ID, "reporta_a_id": ABUELO_ID},
        {"id": HIJO_ID, "reporta_a_id": PADRE_ID},
    ]


def _fake_db_herencia(puesto_vigente_caller, poseedor_directo, heredable):
    """El hijo (poseedor_directo) tiene el código directo y activo; puesto_vigente_caller es
    el (único) puesto vigente de la persona bajo prueba."""
    fake_client = MagicMock()

    def side_effect(nombre_tabla):
        tabla = MagicMock()
        if nombre_tabla == "asignacion":
            tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = [
                {"puesto_id": puesto_vigente_caller}
            ]
        elif nombre_tabla == "puesto_permiso":
            tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = [
                {"puesto_id": poseedor_directo}
            ]
        elif nombre_tabla == "permiso":
            tabla.select.return_value.eq.return_value.execute.return_value.data = [
                {"heredable": heredable}
            ]
        elif nombre_tabla == "puesto":
            tabla.select.return_value.execute.return_value.data = _arbol_tres_niveles()
        return tabla

    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    return fake_client


def test_tiene_permiso_abuelo_hereda_del_hijo_a_traves_del_padre():
    """El HIJO tiene el permiso heredable directo; el ABUELO (dos niveles arriba) también lo
    tiene por herencia -- RTB-ESP-01 §III.4, el jefe hereda lo del subordinado."""
    fake_client = _fake_db_herencia(
        puesto_vigente_caller=ABUELO_ID, poseedor_directo=HIJO_ID, heredable=True
    )

    assert tiene_permiso(fake_client, PERSONA_ID, CODIGO_HEREDABLE) is True


def test_tiene_permiso_padre_tambien_hereda_del_hijo():
    """Mismo árbol, ahora la persona bajo prueba está en el puesto PADRE (un nivel arriba del
    hijo que tiene el permiso directo) -- también debe heredarlo."""
    fake_client = _fake_db_herencia(
        puesto_vigente_caller=PADRE_ID, poseedor_directo=HIJO_ID, heredable=True
    )

    assert tiene_permiso(fake_client, PERSONA_ID, CODIGO_HEREDABLE) is True


def test_tiene_permiso_no_heredable_no_sube_por_el_organigrama():
    """Control: mismo árbol, mismo poseedor directo (HIJO), pero el permiso NO es heredable --
    el ABUELO no debe heredarlo aunque esté en la línea directa de mando."""
    fake_client = _fake_db_herencia(
        puesto_vigente_caller=ABUELO_ID, poseedor_directo=HIJO_ID, heredable=False
    )

    assert tiene_permiso(fake_client, PERSONA_ID, CODIGO_NO_HEREDABLE) is False


def test_tiene_permiso_sin_puestos_vigentes_devuelve_false():
    """Persona sin ninguna asignación vigente -- no puede tener ningún permiso, ni siquiera
    consulta puesto_permiso (corta apenas ve la lista de puestos vigentes vacía)."""
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.return_value.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = (
        []
    )

    assert tiene_permiso(fake_client, PERSONA_ID, CODIGO_HEREDABLE) is False


def _fake_db_edicion_implica_lectura(puesto_vigente_caller):
    """El caller sólo tiene area_edicion en su puesto vigente -- ni área_lectura ni ningún otro
    código. tiene_alguno("area_lectura", "area_edicion") debe devolver True igual, porque
    edición-implica-lectura no es una regla de datos sino de orden de chequeo del gate: basta
    con tener CUALQUIERA de los códigos pasados a requiere_permiso."""
    fake_client = MagicMock()

    def eq_codigo(_campo, codigo):
        siguiente = MagicMock()

        def eq_activo(_campo2, _valor2):
            ejecutable = MagicMock()
            datos = [{"puesto_id": puesto_vigente_caller}] if codigo == "area_edicion" else []
            ejecutable.execute.return_value.data = datos
            return ejecutable

        siguiente.eq.side_effect = eq_activo
        return siguiente

    def side_effect(nombre_tabla):
        tabla = MagicMock()
        if nombre_tabla == "asignacion":
            tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = [
                {"puesto_id": puesto_vigente_caller}
            ]
        elif nombre_tabla == "puesto_permiso":
            tabla.select.return_value.eq.side_effect = eq_codigo
        elif nombre_tabla == "permiso":
            # ni area_lectura ni nada más es heredable en este escenario -- no hay forma de
            # que el caller termine con area_lectura salvo por tenerla directa.
            tabla.select.return_value.eq.return_value.execute.return_value.data = [
                {"heredable": False}
            ]
        return tabla

    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    return fake_client


def test_tiene_alguno_con_solo_edicion_pasa_el_chequeo_de_lectura_o_edicion():
    fake_client = _fake_db_edicion_implica_lectura(puesto_vigente_caller="puesto-ficticio-solo-edicion")

    assert tiene_alguno(fake_client, PERSONA_ID, "area_lectura", "area_edicion") is True


def test_tiene_alguno_sin_ningun_codigo_devuelve_false():
    fake_client = _fake_db_edicion_implica_lectura(puesto_vigente_caller="puesto-sin-nada")
    # Sobreescribimos para que ni area_edicion tenga match.
    fake_client.postgrest.schema.return_value.table.side_effect = lambda nombre: (
        MagicMock(
            **{
                "select.return_value.eq.return_value.is_.return_value.execute.return_value.data": [
                    {"puesto_id": "puesto-sin-nada"}
                ]
            }
        )
        if nombre == "asignacion"
        else MagicMock(
            **{
                "select.return_value.eq.return_value.eq.return_value.execute.return_value.data": [],
                "select.return_value.eq.return_value.execute.return_value.data": [
                    {"heredable": False}
                ],
            }
        )
    )

    assert tiene_alguno(fake_client, PERSONA_ID, "area_lectura", "area_edicion") is False
