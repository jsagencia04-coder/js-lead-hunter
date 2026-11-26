import os
import subprocess
import sys
import uuid
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ["NO_PROXY"] = "127.0.0.1,localhost"
os.environ["no_proxy"] = "127.0.0.1,localhost"

REPO = Path(__file__).resolve().parents[2]


@pytest.fixture
def empty_db():
    """Segundo banco com estrutura e sem dados (destino de testes de restauração)."""
    yield from fresh_db.__wrapped__()


@pytest.fixture
def fresh_db():
    """Banco limpo com o stub do Supabase + todas as migrations.

    Requer TEST_DATABASE_URL apontando para um servidor Postgres (banco 'postgres').
    """
    base = os.getenv("TEST_DATABASE_URL")
    if not base:
        pytest.skip("TEST_DATABASE_URL não definida")
    import psycopg
    import psycopg.conninfo

    name = "jslh_" + uuid.uuid4().hex[:8]
    with psycopg.connect(base, autocommit=True) as c:
        c.execute(f"CREATE DATABASE {name}")
    url = psycopg.conninfo.make_conninfo(base, dbname=name)
    files = [REPO / "supabase/tests/00_supabase_stub.sql", *sorted((REPO / "supabase/migrations").glob("*.sql"))]
    for f in files:
        subprocess.run(["psql", url, "-q", "-X", "-v", "ON_ERROR_STOP=1", "-f", str(f)],
                       check=True, capture_output=True)
    yield url
    with psycopg.connect(base, autocommit=True) as c:
        c.execute(f"DROP DATABASE {name} WITH (FORCE)")
