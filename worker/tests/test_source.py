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


def test_leitura_em_blocos_preserva_linhas(tmp_path):
    import zipfile

    from lead_hunter.transform import iter_zip_chunks

    lines = [f'"{i:08d}";"NOME {i} S\xc3O";"X"\n'.encode("latin-1") for i in range(5000)]
    z = tmp_path / "Teste.zip"
    with zipfile.ZipFile(z, "w") as zf:
        zf.writestr("TESTE", b"".join(lines)[:-1])  # último registro sem quebra de linha
    chunks = list(iter_zip_chunks(z, tmp_path / "c", chunk_bytes=4096))
    assert len(chunks) > 10
    data = b"".join(p.read_bytes() for p, _ in chunks).decode("utf-8")
    assert data == b"".join(lines).decode("latin-1")  # blocos saem convertidos para UTF-8
    assert sum(n for _, n in chunks) == 5000


def test_conversao_para_utf8():
    from lead_hunter.transform import to_utf8

    # Latin-1 puro
    assert to_utf8("SÃO JOÃO".encode("latin-1")).decode() == "SÃO JOÃO"
    # Windows-1252: aspas tipográficas e travessão (bytes 0x93, 0x94, 0x96)
    assert to_utf8(b'"\x93BAR DO Z\xc9\x94 \x96 ME"').decode() == '"“BAR DO ZÉ” – ME"'
    # byte sem mapeamento no cp1252 (0x81) não derruba a leitura
    assert to_utf8(b"A\x81B").decode() == "A\x81B"
    # já em UTF-8: inalterado
    assert to_utf8("Ação".encode()) == "Ação".encode()


def test_corte_de_bloco_respeita_quebra_de_linha_entre_aspas(tmp_path):
    import zipfile

    from lead_hunter.transform import iter_zip_chunks

    recs = []
    for i in range(3000):
        comp = "SALA 1\nFUNDOS" if i % 7 == 0 else "SALA 1"
        recs.append(f'"{i:08d}";"{comp}";"X"\n'.encode("latin-1"))
    z = tmp_path / "Q.zip"
    with zipfile.ZipFile(z, "w") as zf:
        zf.writestr("Q", b"".join(recs))
    chunks = list(iter_zip_chunks(z, tmp_path / "c", chunk_bytes=997))
    assert len(chunks) > 20
    for p, _ in chunks:
        data = p.read_bytes()
        assert data.count(b'"') % 2 == 0, "bloco cortou um registro no meio"
    assert b"".join(p.read_bytes() for p, _ in chunks) == b"".join(recs)
