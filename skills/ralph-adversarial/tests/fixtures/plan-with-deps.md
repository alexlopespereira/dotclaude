# Plano fixture (US-02 AC1)

Plano sintético para testar o extrator de dependências do `/prd-convert`.

## Próxima Fatia (US-01)

Implementar helpers puros de despacho. Story totalmente independente, sem
dependências. Cobre lib/dispatch.sh.

## Fatia subsequente (US-02)

Estender validador. Esta fatia **depende de US-01** porque consome os helpers
puros (cycle detection + slot phase) já entregues lá.

## Fatia subsequente (US-03)

Mocks para fake-claude e fake-codex. Independente da Fatia 2 mas **depende das
US-01** para ler dispatch.sh durante setup. Também menciona que pode coexistir.

## Fatia subsequente (US-04)

Pós-validação. **Depende de US-01** e **depende de US-03** (precisa dos mocks
para FAKE_OUTCOME=amend-violation).
