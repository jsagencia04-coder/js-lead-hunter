"""Validação de CNPJ numérico e alfanumérico (IN RFB nº 2.229/2024).

Valor de cada caractere = código ASCII - 48 (0-9 → 0-9, A → 17 ... Z → 42).
Os dois últimos caracteres (DV) são sempre numéricos.
"""
import re

_PATTERN = re.compile(r"^[0-9A-Z]{12}[0-9]{2}$")
_W1 = [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
_W2 = [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]

# Usado também nas expressões vetorizadas do Polars
CHAR_VALUE = {c: ord(c) - 48 for c in "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"}
WEIGHTS_1 = _W1
WEIGHTS_2 = _W2


def _dv(values: list[int], weights: list[int]) -> int:
    r = sum(v * w for v, w in zip(values, weights)) % 11
    return 0 if r < 2 else 11 - r


def compute_dv(base12: str) -> str:
    vals = [CHAR_VALUE[c] for c in base12]
    d1 = _dv(vals, _W1)
    d2 = _dv(vals + [d1], _W2)
    return f"{d1}{d2}"


def is_valid(cnpj: str | None) -> bool:
    if not cnpj:
        return False
    cnpj = cnpj.strip().upper()
    if not _PATTERN.match(cnpj) or len(set(cnpj)) == 1:
        return False
    return compute_dv(cnpj[:12]) == cnpj[12:]
