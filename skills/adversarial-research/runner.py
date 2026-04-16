#!/usr/bin/env python3
"""
Adversarial Deep Research Runner (3 provedores)
Gemini (elaborador) + Perplexity (fact-check) + OpenAI (lógica adversária)
"""
import os, sys, json, time, re, argparse, requests
from pathlib import Path
from datetime import datetime

# ─── Config ─────────────────────────────────────────────────
GEMINI_KEY = os.environ.get("GEMINI_API_KEY")
PPLX_KEY   = os.environ.get("PERPLEXITY_API_KEY")
OPENAI_KEY = os.environ.get("OPENAI_API_KEY")

GEMINI_AGENT = "deep-research-pro-preview-12-2025"
GEMINI_URL   = "https://generativelanguage.googleapis.com/v1beta/interactions"
PPLX_URL     = "https://api.perplexity.ai/v1/sonar"
PPLX_MODEL   = "sonar-deep-research"
OPENAI_URL   = "https://api.openai.com/v1/responses"
OPENAI_MODEL = os.environ.get("OPENAI_REVIEW_MODEL", "gpt-4o")

MAX_CYCLES     = 3
POLL_INTERVAL  = 15
POLL_TIMEOUT   = 600


def check_keys():
    missing = [k for k, v in [("GEMINI_API_KEY", GEMINI_KEY),
        ("PERPLEXITY_API_KEY", PPLX_KEY), ("OPENAI_API_KEY", OPENAI_KEY)] if not v]
    if missing:
        print(f"ERRO: Faltam: {', '.join(missing)}")
        sys.exit(1)

def slugify(t):
    t = re.sub(r'[^\w\s-]', '', t.lower().strip())
    return re.sub(r'[\s_]+', '-', t)[:60]

def mkdir(topic):
    d = Path(".claude/research") / f"{datetime.now().strftime('%Y%m%d-%H%M%S')}_{slugify(topic)}"
    d.mkdir(parents=True, exist_ok=True)
    return d

def save(d, name, txt):
    p = d / name; p.write_text(txt, encoding="utf-8"); print(f"  > {p}"); return p


# ─── GEMINI DEEP RESEARCH ──────────────────────────────────

def gemini(prompt):
    print("  [Gemini] Iniciando deep research...")
    r = requests.post(f"{GEMINI_URL}?key={GEMINI_KEY}", json={
        "input": [{"type": "text", "text": prompt}],
        "agent": GEMINI_AGENT, "background": True
    }, timeout=30)
    if r.status_code != 200:
        raise Exception(f"Gemini create {r.status_code}: {r.text[:500]}")
    iid = r.json().get("name") or r.json().get("id") or r.json().get("interactionId")
    if not iid: raise Exception(f"Sem interaction_id: {r.text[:500]}")
    print(f"  [Gemini] ID: {iid}")

    for elapsed in range(POLL_INTERVAL, POLL_TIMEOUT + 1, POLL_INTERVAL):
        time.sleep(POLL_INTERVAL)
        p = requests.get(f"{GEMINI_URL}/{iid}?key={GEMINI_KEY}", timeout=30)
        if p.status_code != 200:
            print(f"  [Gemini] aguardando... ({elapsed}s)"); continue
        d = p.json(); st = d.get("status","?")
        if st == "completed":
            for o in d.get("outputs", []):
                if isinstance(o, dict) and "text" in o:
                    print(f"  [Gemini] OK ({elapsed}s)"); return o["text"]
            c = d.get("content", d.get("result", ""))
            if isinstance(c, str) and c: return c
            return json.dumps(d, indent=2, ensure_ascii=False)
        elif st == "failed":
            raise Exception(f"Gemini falhou: {d.get('error')}")
        else:
            m, s = divmod(elapsed, 60); print(f"  [Gemini] {st} ({m}m{s}s)")
    raise Exception(f"Gemini timeout ({POLL_TIMEOUT}s)")


# ─── PERPLEXITY SONAR DR ───────────────────────────────────

def perplexity(prompt):
    print("  [Perplexity] Iniciando fact-check...")
    r = requests.post(PPLX_URL, headers={
        "Authorization": f"Bearer {PPLX_KEY}", "Content-Type": "application/json"
    }, json={"model": PPLX_MODEL, "messages": [{"role": "user", "content": prompt}]}, timeout=600)
    if r.status_code != 200:
        raise Exception(f"Perplexity {r.status_code}: {r.text[:500]}")
    d = r.json()
    txt = ""
    if "choices" in d: txt = d["choices"][0]["message"]["content"]
    elif "content" in d: txt = d["content"]
    elif "output" in d: txt = d["output"]
    cites = d.get("citations", [])
    if cites:
        txt += "\n\n## Fontes Consultadas\n"
        for i, c in enumerate(cites, 1):
            txt += f"{i}. {c if isinstance(c, str) else c.get('url', str(c))}\n"
    print(f"  [Perplexity] OK"); return txt


# ─── OPENAI RESPONSES API + WEB SEARCH ─────────────────────

def openai_review(prompt):
    print(f"  [OpenAI] Iniciando revisão lógica ({OPENAI_MODEL} + web search)...")
    r = requests.post(OPENAI_URL, headers={
        "Authorization": f"Bearer {OPENAI_KEY}", "Content-Type": "application/json"
    }, json={
        "model": OPENAI_MODEL,
        "tools": [{"type": "web_search_preview", "search_context_size": "medium"}],
        "input": prompt
    }, timeout=600)
    if r.status_code != 200:
        raise Exception(f"OpenAI {r.status_code}: {r.text[:500]}")
    d = r.json()
    # Extrair texto do output
    txt = d.get("output_text", "")
    if not txt:
        parts = []
        for item in d.get("output", []):
            if item.get("type") == "message":
                for c in item.get("content", []):
                    if c.get("type") == "output_text":
                        parts.append(c.get("text", ""))
        txt = "\n".join(parts)
    usage = d.get("usage", {})
    print(f"  [OpenAI] OK | tokens: {usage.get('total_tokens', '?')}")
    return txt


# ─── PROMPTS ────────────────────────────────────────────────

def p_elaborate(topic, lang="pt-BR"):
    return f"""Conduza pesquisa profunda sobre:

## Tema
{topic}

## Instrucoes
1. Pesquise extensivamente (fontes primarias, papers, docs oficiais, dados).
2. Relatorio em {lang} com: Resumo Executivo, Contexto, Analise Principal, Dados Quantitativos, Implicacoes, Limitacoes e Incertezas, Referencias (URLs).
3. Para CADA claim factual: [Fonte: URL].
4. Dados conflitantes: apresente ambas versoes.
5. NAO invente dados ou fontes."""


def p_factcheck(topic, report, cycle):
    return f"""Voce e um REVISOR DE FATOS. Verifique o relatorio abaixo buscando fontes independentes.

Tema: "{topic}" | Rodada: {cycle}

<report>
{report}
</report>

## Tarefas
1. Para cada claim factual importante: busque fontes INDEPENDENTES para verificar.
2. Identifique: dados errados, desatualizados, fabricados, URLs inexistentes.
3. Busque CONTRA-EVIDENCIAS que o relatorio ignorou.
4. Liste o que esta CORRETO (verificado com fontes independentes).

## Formato do Parecer

## Parecer de Fact-Check — Rodada {cycle}

### Claims Incorretos ou Imprecisos
| # | Claim | Problema | Severidade | Correcao (com fonte) |
|---|-------|----------|------------|----------------------|

### Claims Verificados como Corretos
### Contra-Evidencias Encontradas
### Fontes Ausentes ou Importantes Ignoradas
### URLs Citadas que Nao Existem ou Dizem Algo Diferente"""


def p_logic(topic, report, cycle):
    return f"""Voce e um REVISOR ADVERSARIO DE LOGICA. Analise consistencia, metodologia e raciocinios.

Tema: "{topic}" | Rodada: {cycle}

<report>
{report}
</report>

## Tarefas
1. CONSISTENCIA: ha contradicoes internas? Dados incompativeis entre secoes?
2. METODOLOGIA: as conclusoes seguem das evidencias? Ha saltos logicos?
3. LACUNAS: que perspectivas, stakeholders ou cenarios foram ignorados?
4. VIESES: ha vies de selecao nas fontes? Vies de confirmacao nas conclusoes?
5. ROBUSTEZ: as conclusoes resistem se mudarmos uma premissa-chave?

## Formato do Parecer

## Parecer de Logica — Rodada {cycle}
**Veredicto:** [APROVADO / APROVADO COM RESSALVAS / REPROVADO]

### Inconsistencias Internas
| # | Secao A | Secao B | Contradicao |
|---|---------|---------|-------------|

### Saltos Logicos ou Conclusoes Infundadas
### Lacunas Metodologicas
### Vieses Detectados
### Premissas Frageis (se mudar X, a conclusao muda?)
### Recomendacoes de Correcao"""


def p_correct(topic, report, fc_review, logic_review, cycle):
    return f"""Corrija o relatorio sobre "{topic}" com base em DOIS pareceres independentes.

## Relatorio V{cycle}
<report>
{report}
</report>

## Parecer de Fact-Check (Perplexity)
<factcheck>
{fc_review}
</factcheck>

## Parecer de Logica (OpenAI)
<logic>
{logic_review}
</logic>

## Tarefas
1. CORRIJA todos os erros factuais do parecer de fact-check.
2. RESOLVA todas as inconsistencias logicas apontadas.
3. PREENCHA lacunas metodologicas com pesquisa adicional.
4. REMOVA claims nao verificaveis ou marque como [NAO VERIFICADO].
5. Se ha contra-evidencias, apresente AMBOS os lados.
6. MANTENHA intacto o que foi confirmado.
7. Adicione secao "## Correcoes Aplicadas" no final.

Relatorio COMPLETO corrigido, mesma estrutura."""


# ─── PIPELINE ──────────────────────────────────────────────

def run(topic, max_c=MAX_CYCLES, lang="pt-BR"):
    check_keys()
    d = mkdir(topic)
    print(f"\n{'='*60}")
    print(f"ADVERSARIAL DEEP RESEARCH (3 provedores)")
    print(f"{'='*60}")
    print(f"Tema:        {topic}")
    print(f"Artefatos:   {d}")
    print(f"Elaborador:  Gemini Deep Research")
    print(f"Fact-check:  Perplexity Sonar DR")
    print(f"Logica:      OpenAI {OPENAI_MODEL} + web search")
    print(f"Max ciclos:  {max_c}")
    print(f"{'='*60}\n")

    meta = {"topic": topic, "lang": lang, "max_cycles": max_c,
        "started": datetime.now().isoformat(),
        "providers": {"elaborator": f"Gemini/{GEMINI_AGENT}",
            "factcheck": f"Perplexity/{PPLX_MODEL}",
            "logic": f"OpenAI/{OPENAI_MODEL}+web_search"}}
    save(d, "meta.json", json.dumps(meta, indent=2, ensure_ascii=False))

    report = fc = logic = None

    for c in range(1, max_c + 1):
        print(f"\n--- CICLO {c}/{max_c} ---")

        # A: Gemini elabora/corrige
        if c == 1:
            print(f"\n[A] Elaboracao V1")
            prompt = p_elaborate(topic, lang)
        else:
            print(f"\n[A] Correcao V{c}")
            prompt = p_correct(topic, report, fc, logic, c - 1)
        save(d, f"prompt-gemini-v{c}.txt", prompt)
        try:
            report = gemini(prompt)
            save(d, f"report-v{c}.md", report)
        except Exception as e:
            save(d, f"error-gemini-v{c}.txt", str(e)); print(f"  ERRO: {e}"); break

        # B: Perplexity fact-check
        print(f"\n[B] Fact-Check (Perplexity)")
        fp = p_factcheck(topic, report, c)
        save(d, f"prompt-pplx-{c}.txt", fp)
        try:
            fc = perplexity(fp)
            save(d, f"factcheck-{c}.md", fc)
        except Exception as e:
            save(d, f"error-pplx-{c}.txt", str(e)); print(f"  ERRO: {e}"); fc = "(falhou)";

        # C: OpenAI revisão lógica
        print(f"\n[C] Revisao Logica (OpenAI)")
        lp = p_logic(topic, report, c)
        save(d, f"prompt-openai-{c}.txt", lp)
        try:
            logic = openai_review(lp)
            save(d, f"logic-review-{c}.md", logic)
        except Exception as e:
            save(d, f"error-openai-{c}.txt", str(e)); print(f"  ERRO: {e}"); logic = "(falhou)"

        # D: Checar veredicto
        vtext = (logic or "").lower()
        if "aprovado com ressalvas" in vtext:
            print(f"\n  Veredicto: APROVADO COM RESSALVAS")
            if c < max_c: continue
            else: break
        elif "reprovado" in vtext:
            print(f"\n  Veredicto: REPROVADO")
            if c < max_c: continue
            else: break
        elif "aprovado" in vtext:
            print(f"\n  Veredicto: APROVADO"); break
        else:
            if c >= max_c: break

    meta["completed"] = datetime.now().isoformat()
    meta["cycles"] = c
    save(d, "meta.json", json.dumps(meta, indent=2, ensure_ascii=False))

    print(f"\n{'='*60}")
    print(f"CONCLUIDO | {d}")
    for f in sorted(d.iterdir()):
        print(f"  {f.name} ({f.stat().st_size:,}b)")
    print(f"\nProximo: peca ao Claude Code sintetizar:")
    print(f'  "Leia {d} e produza sintese final com mapa de confianca."')
    print(f"{'='*60}\n")
    return d


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Adversarial Deep Research: Gemini+Perplexity+OpenAI")
    ap.add_argument("topic")
    ap.add_argument("--cycles", "-c", type=int, default=MAX_CYCLES)
    ap.add_argument("--lang", "-l", default="pt-BR")
    ap.add_argument("--openai-model", "-m", default=None, help="OpenAI model (default: gpt-4o)")
    a = ap.parse_args()
    if a.openai_model: OPENAI_MODEL = a.openai_model
    run(a.topic, a.cycles, a.lang)
