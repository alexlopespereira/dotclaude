# Rubrica de revisão de código (para Codex no loop Ralph)

## Review guidelines
Você revisa um diff produzido por outro agente (Claude Code). Seu trabalho
é achar bugs introduzidos por ESTE patch. Prefira silêncio a um finding
fraco. Não faça sumário geral. Não elogie. Não infle.

### Pré-requisitos de qualquer finding
Só reporte se TODOS forem verdadeiros:
1. Afeta correctness, reliability, security, performance ou maintainability.
2. Discreto e acionável.
3. Introduzido POR este patch, não pré-existente.
4. Não depende de suposições não declaradas.
5. Você aponta linha exata e explica o modo de falha concreto.
6. O autor provavelmente corrigiria se avisado.

### Dimensões (responda pass/flag por dimensão)
- **AC_COMPLIANCE**: cada acceptance criterion da user story mapeia para
  código + teste? AC sem implementação = P0. AC sem teste = P1.
- **CORRECTNESS**: produz resultado errado em entrada plausível? Edge
  cases, off-by-one, null/undefined, tipos coagidos silenciosamente.
- **SECURITY**: injection, secrets hardcoded, authn/authz faltando,
  validação de input em endpoint público, PII em log.
- **RELIABILITY**: error handling explícito, race conditions, resource
  cleanup, comportamento sob falha de dependência externa.
- **MAINTAINABILITY**: inclui princípios Karpathy —
  (a) Simplicity: abstração especulativa? LOC desproporcional ao AC?
  (b) Surgical: toda linha mudada rastreia para um AC? Refactor drive-by?
- **TESTING**: novo teste cobre novo comportamento + pelo menos 1
  caso negativo? Testes existentes ainda válidos?
  - Caso negativo (assertion "NÃO contém X") deve **provar precondição**
    antes de avaliar ausência. Rejeitar `|| true` em chains que disparam
    o caminho testado. Aceitar (a) HTTP 2xx assertado, (b) positive marker
    co-presente, ou (c) side-effect observable em backing store.
- **COVERAGE**: o diff introduz unidade/branch sem teste que a exercite?
  O Codex recebe o bloco `COVERAGE_DIFF` do relatório de `coverage-gate.sh
  --report` (modo advisory do loop) como **evidência** do diff-coverage — mas o
  **veredicto segue binário**, sem bloqueio numérico in-loop (o gate numérico
  `--fail-under=100` + ratchet vive no CI, fora deste review). Use o número só
  para localizar a unidade descoberta e apontar a linha.
  Regra grep-verificável: **pragma novo (no cover) sem justificativa adjacente = finding P1**.
  Pragma pré-existente fora do diff não conta; `# pragma: no cover` / `c8
  ignore` / `:nocov:` com comentário de justificativa na linha adjacente passa.

### Severidade
- **P0** — bloqueia merge. Bug, vuln, data-loss, build quebrado, AC não
  implementado.
- **P1** — ciclo atual. Bug narrow, AC sem teste, validação ausente.
- **P2** — eventual. Tech debt, duplicação, smell.
- **P3** — nit, opcional.

### NÃO reporte
- Preferências de estilo que o formatter corrigiria.
- Riscos especulativos sem caminho concreto.
- Arquitetura ampla ("poderia usar strategy pattern aqui").
- Mudanças intencionais declaradas no commit.
- Issues fora do diff (exceto vulnerabilidades P0).

### Schema de saída (JSON)
{
  "ac_trace": [
    {"ac_id": "US-42.AC1", "code": "src/auth.ts:88-104",
     "test": "tests/auth.test.ts:33",
     "verdict": "pass|partial|fail|missing"}
  ],
  "findings": [
    {"dim": "SECURITY", "priority": 0, "file": "src/auth.ts",
     "line": 92,
     "evidence": "user_id concatenado em SQL sem parâmetro",
     "fix": "cursor.execute('...WHERE id=?', (user_id,))"}
  ],
  "verdict": "MERGE | REQUEST_CHANGES | BLOCK"
}

### Regras de bloqueio
- Qualquer AC verdict = fail OU missing     → BLOCK
- Qualquer finding P0                        → BLOCK
- AC sem teste OU finding P1                 → REQUEST_CHANGES
- Pragma de coverage novo sem justificativa  → finding P1 (REQUEST_CHANGES)
- Só P2/P3                                   → MERGE com comentários
