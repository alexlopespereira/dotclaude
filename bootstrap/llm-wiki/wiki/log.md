# LLM Wiki — Audit Log

Registro cronológico de intervenções do agente. Formato:

```
- YYYY-MM-DD HH:MM | PR #<n> | <páginas afetadas> | <resumo em 1 linha>
```

Entradas especiais:
- `merge-conflict-resolved`: agente resolveu conflito semântico em `wiki/`.
- `bootstrap`: inicialização do repo.
- `stale-rebase`: `wiki-lint.py --fix` rebaixou `confidence` de páginas desatualizadas.

---
