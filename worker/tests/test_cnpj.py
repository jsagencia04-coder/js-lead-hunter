import polars as pl

from lead_hunter.cnpj import compute_dv, is_valid
from lead_hunter.transform import _cnpj_valid_expr


def test_numerico():
    assert is_valid("11222333000181")
    assert not is_valid("11222333000182")


def test_alfanumerico_exemplo_oficial():
    assert compute_dv("12ABC34501DE") == "35"
    assert is_valid("12ABC34501DE35")


def test_invalidos():
    for v in [None, "", "00000000000000", "1122233300018", "11222333000l81"]:
        assert not is_valid(v)


def test_expressao_polars_igual_ao_python():
    amostra = ["11222333000181", "11222333000182", "12ABC34501DE35", "12ABC34501DE36",
               "00000000000000", "ZZZZZZZZZZZZ00", "AB" + "C" * 10 + compute_dv("AB" + "C" * 10)]
    df = pl.DataFrame({"cnpj": amostra}).with_columns(_cnpj_valid_expr("cnpj").alias("ok"))
    assert df["ok"].to_list() == [is_valid(c) for c in amostra]


def test_minusculas_sao_normalizadas():
    assert is_valid("12abc34501de35")
