import httpx
import pytest

from lead_hunter.config import Settings
from lead_hunter.rf_source import RFSource, SourceError

from .fake_rf import TOKEN, FakeRF, build_competence


def settings(url, tmp_path, **kw):
    return Settings(database_url="postgresql://x", rf_base_url=url, rf_share_token=TOKEN,
                    data_dir=tmp_path, chunk_mb=1, download_connections=4, **kw)


def test_detecta_competencia_mais_recente_completa(tmp_path):
    root = tmp_path / "rf"
    build_competence(root, "2026-09")
    build_competence(root, "2026-10")
    build_competence(root, "2026-11", omit={"Simples.zip"})  # ainda sendo publicada
    with FakeRF(root) as rf:
        src = RFSource(settings(rf.url, tmp_path))
        assert src.list_competences() == ["2026-09", "2026-10", "2026-11"]
        comp, files = src.latest_complete_competence()
        assert comp == "2026-10"
        assert len(files) == 24


def test_token_errado_gera_erro_claro(tmp_path):
    root = tmp_path / "rf"
    build_competence(root, "2026-10")
    with FakeRF(root) as rf:
        s = Settings(database_url="x", rf_base_url=rf.url, rf_share_token="ERRADO", data_dir=tmp_path)
        with pytest.raises(SourceError, match="401"):
            RFSource(s).list_competences()


def test_download_em_partes_com_falhas_e_retomada(tmp_path):
    root = tmp_path / "rf"
    folder = build_competence(root, "2026-10")
    big = folder / "Estabelecimentos5.zip"
    big.write_bytes(big.read_bytes() + b"")  # garante existência
    # arquivo de ~3 MB para forçar várias partes de 1 MB
    import os
    import zipfile
    with zipfile.ZipFile(big, "w", zipfile.ZIP_STORED) as z:
        z.writestr("ESTABELE5", os.urandom(3 * 1024 * 1024))
    with FakeRF(root) as rf:
        rf.handler.fail_ranges[str(big)] = 3  # três respostas 503 seguidas
        src = RFSource(settings(rf.url, tmp_path))
        f = next(x for x in src.list_files("2026-10") if x.name == "Estabelecimentos5.zip")
        out = src.fetch("2026-10", f, tmp_path / "dl")
        assert out.read_bytes() == big.read_bytes()
        # segunda chamada reaproveita o arquivo (idempotente)
        assert src.fetch("2026-10", f, tmp_path / "dl") == out


def test_zip_corrompido_e_rejeitado(tmp_path):
    root = tmp_path / "rf"
    build_competence(root, "2026-10", corrupt={"Cnaes.zip"})
    with FakeRF(root) as rf:
        src = RFSource(settings(rf.url, tmp_path))
        f = next(x for x in src.list_files("2026-10") if x.name == "Cnaes.zip")
        try:
            src.fetch("2026-10", f, tmp_path / "dl")
        except (SourceError, httpx.HTTPError):
            return
        # se o diretório central sobreviveu, a corrupção será detectada pelo CRC na leitura
        from lead_hunter.transform import extract_zip
        import zipfile
        with pytest.raises((zipfile.BadZipFile, Exception)):
            extract_zip(tmp_path / "dl" / "Cnaes.zip", tmp_path / "x")
