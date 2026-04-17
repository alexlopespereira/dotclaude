#!/usr/bin/env python3
"""
wiki-lint.py — Validador estrutural da LLM Wiki.

Regras verificadas:
  1. Toda página .md em wiki/ (exceto log.md) tem frontmatter YAML válido.
  2. Frontmatter contém: source_files (lista), last_verified_commit (sha), confidence (high|medium|low).
  3. Cada caminho em source_files existe no repositório.
  4. last_verified_commit existe no git log.
  5. Se source_files foram modificados APÓS last_verified_commit, a página é considerada stale:
     - Se confidence == 'high': ERRO (força low ou atualização).
     - Se confidence != 'high': WARN (aceitável).
  6. Links cruzados [[página]] não são órfãos.

Uso:
  python wiki-lint.py           # valida wiki/ no diretório atual
  python wiki-lint.py --fix     # rebaixa confidence automaticamente em páginas stale
  python wiki-lint.py --strict  # qualquer WARN vira ERRO

Saída: exit 0 se tudo ok, exit 1 se erros, exit 2 se args inválidos.
Sem dependências além de PyYAML.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERRO: PyYAML ausente. Instale com: pip install pyyaml", file=sys.stderr)
    sys.exit(2)


WIKI_DIR = Path("wiki")
FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n", re.DOTALL)
LINK_RE = re.compile(r"\[\[([^\]]+)\]\]")
REQUIRED_FIELDS = {"source_files", "last_verified_commit", "confidence"}
VALID_CONFIDENCE = {"high", "medium", "low"}
EXEMPT_FILES = {"log.md", "index.md"}  # index e log não precisam de frontmatter estrito


class LintResult:
    def __init__(self):
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def err(self, path: Path, msg: str):
        self.errors.append(f"ERRO {path}: {msg}")

    def warn(self, path: Path, msg: str):
        self.warnings.append(f"WARN {path}: {msg}")

    def ok(self) -> bool:
        return not self.errors


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=False
    ).stdout.strip()


def commit_exists(sha: str) -> bool:
    r = subprocess.run(
        ["git", "cat-file", "-e", f"{sha}^{{commit}}"],
        capture_output=True,
        check=False,
    )
    return r.returncode == 0


def files_changed_since(sha: str, paths: list[str]) -> list[str]:
    if not commit_exists(sha):
        return []
    out = git("diff", "--name-only", f"{sha}..HEAD", "--", *paths)
    return [line for line in out.splitlines() if line]


def parse_frontmatter(text: str) -> tuple[dict | None, str]:
    m = FRONTMATTER_RE.match(text)
    if not m:
        return None, text
    try:
        data = yaml.safe_load(m.group(1))
    except yaml.YAMLError:
        return None, text
    body = text[m.end():]
    return data if isinstance(data, dict) else None, body


def wiki_pages() -> list[Path]:
    if not WIKI_DIR.is_dir():
        return []
    return sorted(p for p in WIKI_DIR.rglob("*.md") if p.is_file())


def all_wiki_titles() -> set[str]:
    return {p.stem for p in wiki_pages()}


def lint_page(path: Path, titles: set[str], result: LintResult, fix: bool) -> None:
    text = path.read_text(encoding="utf-8")
    is_exempt = path.name in EXEMPT_FILES and path.parent == WIKI_DIR

    fm, body = parse_frontmatter(text)

    if fm is None:
        if is_exempt:
            return
        result.err(path, "frontmatter YAML ausente ou inválido")
        return

    missing = REQUIRED_FIELDS - set(fm.keys())
    if missing and not is_exempt:
        result.err(path, f"frontmatter sem campos obrigatórios: {sorted(missing)}")
        return

    if is_exempt:
        _lint_cross_links(path, body, titles, result)
        return

    source_files = fm.get("source_files") or []
    if not isinstance(source_files, list) or not source_files:
        result.err(path, "source_files deve ser lista não-vazia")
        return

    for src in source_files:
        if not Path(src).exists():
            result.err(path, f"source_files aponta para caminho inexistente: {src}")

    confidence = fm.get("confidence")
    if confidence not in VALID_CONFIDENCE:
        result.err(path, f"confidence inválido: {confidence!r} (esperado high|medium|low)")
        return

    sha = fm.get("last_verified_commit")
    if not isinstance(sha, str) or not sha:
        result.err(path, "last_verified_commit ausente")
        return

    if not commit_exists(sha):
        result.err(path, f"last_verified_commit não existe no git log: {sha}")
        return

    changed = files_changed_since(sha, source_files)
    if changed:
        if confidence == "high":
            if fix:
                _rebase_confidence(path, text, fm, "medium")
                result.warn(path, f"stale: confidence rebaixado para 'medium' (arquivos mudaram: {changed})")
            else:
                result.err(
                    path,
                    f"stale com confidence=high (arquivos mudaram após {sha[:8]}: {changed}). "
                    "Atualize o conteúdo ou rebaixe confidence.",
                )
        else:
            result.warn(path, f"stale (arquivos mudaram após {sha[:8]}: {changed})")

    _lint_cross_links(path, body, titles, result)


def _lint_cross_links(path: Path, body: str, titles: set[str], result: LintResult) -> None:
    for m in LINK_RE.finditer(body):
        target = m.group(1).strip()
        if target and target not in titles:
            result.warn(path, f"link órfão: [[{target}]]")


def _rebase_confidence(path: Path, text: str, fm: dict, new_value: str) -> None:
    fm["confidence"] = new_value
    new_fm = yaml.safe_dump(fm, sort_keys=False, allow_unicode=True).strip()
    body = FRONTMATTER_RE.sub("", text, count=1)
    path.write_text(f"---\n{new_fm}\n---\n{body}", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description="LLM Wiki linter")
    ap.add_argument("--fix", action="store_true", help="rebaixar confidence em páginas stale")
    ap.add_argument("--strict", action="store_true", help="qualquer WARN vira ERRO")
    args = ap.parse_args()

    if not WIKI_DIR.is_dir():
        print(f"ERRO: {WIKI_DIR}/ não encontrado. Rode a partir da raiz do repo.", file=sys.stderr)
        return 1

    if not Path(".git").is_dir() and not Path(".git").is_file():
        print("ERRO: não é um repositório git.", file=sys.stderr)
        return 1

    result = LintResult()
    titles = all_wiki_titles()
    pages = wiki_pages()

    if not pages:
        print("wiki/ vazio — nada a validar.")
        return 0

    for page in pages:
        lint_page(page, titles, result, args.fix)

    for w in result.warnings:
        print(w)
    for e in result.errors:
        print(e, file=sys.stderr)

    if args.strict and result.warnings:
        print(f"\nstrict mode: {len(result.warnings)} WARN tratado como erro.", file=sys.stderr)
        return 1

    if not result.ok():
        print(f"\n{len(result.errors)} erro(s), {len(result.warnings)} aviso(s).", file=sys.stderr)
        return 1

    print(f"OK — {len(pages)} página(s) válida(s), {len(result.warnings)} aviso(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
