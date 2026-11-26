

def test_teste_de_partes_nao_le_o_corpo_e_tenta_de_novo(tmp_path, monkeypatch):
    """Regressão de 26/11/2026: servidor ignorou o Range e derrubou a conexão no teste."""
    import httpx

    from lead_hunter import rf_source

    monkeypatch.setattr(rf_source.time, "sleep", lambda s: None)
    calls = {"n": 0}

    def handler(req):
        calls["n"] += 1
        if calls["n"] == 1:
            raise httpx.RemoteProtocolError("peer closed connection")
        return httpx.Response(206, content=b"P")

    src = rf_source.RFSource.__new__(rf_source.RFSource)
    src.client = httpx.Client(transport=httpx.MockTransport(handler))
    assert src._supports_range("https://exemplo/arquivo.zip") is True
    assert calls["n"] == 2
