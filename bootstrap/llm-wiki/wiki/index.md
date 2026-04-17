---
source_files: []
last_verified_commit: BOOTSTRAP
confidence: low
superseded_by: null
superseded_reason: null
---

# Wiki — Índice Mestre

> Este arquivo é o **entry point** da LLM Wiki. O agente lê este índice primeiro para navegar.
>
> Atualize-o sempre que criar ou remover páginas em `wiki/`.

## Status

- **Bootstrap pendente.** Rode `claude -p "Leia todo src/ e popule wiki/ seguindo AGENTS.md"` para inicializar.
- Após bootstrap, este aviso será substituído pelo mapa real do repositório.

## Estrutura

```
wiki/
├── index.md              # este arquivo
├── log.md                # auditoria de intervenções
├── entidades/            # uma página por módulo (o QUÊ)
├── conceitos/            # padrões transversais
├── decisoes/             # ADRs extraídos de PRs (o POR QUÊ)
├── contradicoes/         # pendentes de revisão humana
└── debugging/ (opcional) # sessões de incidentes
```

## Módulos

<!-- Será preenchido pelo agente no bootstrap. Formato esperado:

### auth
[[auth]] — OAuth, sessões, middleware de autenticação.

### api
[[api]] — Rotas HTTP, validação de entrada, serialização.

-->

## Padrões e Convenções

<!-- Preenchido via wiki/conceitos/ -->

## Decisões Arquiteturais

<!-- Preenchido via wiki/decisoes/ (extraídos de PRs relevantes) -->

## Contradições Abertas

<!-- Preenchido via wiki/contradicoes/ — itens aqui exigem resolução humana -->
