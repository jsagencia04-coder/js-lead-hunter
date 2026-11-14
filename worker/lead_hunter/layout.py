"""Leiaute dos arquivos de dados abertos do CNPJ (sem cabeçalho, ';', aspas, Latin-1)."""

ESTABELECIMENTOS = [
    "cnpj_basico", "cnpj_ordem", "cnpj_dv", "identificador_matriz", "nome_fantasia",
    "situacao_cadastral", "data_situacao_cadastral", "motivo_situacao", "nome_cidade_exterior",
    "pais", "data_inicio_atividade", "cnae_principal", "cnae_secundaria", "tipo_logradouro",
    "logradouro", "numero", "complemento", "bairro", "cep", "uf", "municipio", "ddd1",
    "telefone1", "ddd2", "telefone2", "ddd_fax", "fax", "email", "situacao_especial",
    "data_situacao_especial",
]

EMPRESAS = [
    "cnpj_basico", "razao_social", "natureza_juridica", "qualificacao_responsavel",
    "capital_social", "porte", "ente_federativo",
]

SIMPLES = [
    "cnpj_basico", "opcao_simples", "data_opcao_simples", "data_exclusao_simples",
    "opcao_mei", "data_opcao_mei", "data_exclusao_mei",
]

CODIGO_DESCRICAO = ["codigo", "descricao"]

# Arquivos necessários por competência. Sócios NÃO são baixados (sem CPF/nomes na v1).
REFERENCE_FILES = ["Cnaes.zip", "Municipios.zip", "Naturezas.zip"]
EMPRESAS_FILES = [f"Empresas{i}.zip" for i in range(10)]
ESTABELECIMENTOS_FILES = [f"Estabelecimentos{i}.zip" for i in range(10)]
SIMPLES_FILES = ["Simples.zip"]
REQUIRED_FILES = REFERENCE_FILES + EMPRESAS_FILES + ESTABELECIMENTOS_FILES + SIMPLES_FILES
