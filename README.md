# dotclaude

Configurações globais do [Claude Code](https://claude.ai/code) — commands, skills e instruções compartilhadas entre todos os projetos.

## Estrutura

```
├── CLAUDE.md                          # Instruções globais (ReAct + Feynman)
├── WORKFLOW.md                        # Workflow dos comandos disponíveis
├── commands/                          # Slash commands globais
│   ├── planejar.md                    # /planejar — plano técnico ReAct+Feynman
│   ├── revisar-adversario.md          # /revisar-adversario — revisão Red Team
│   ├── ciclo-completo.md              # /ciclo-completo — planeja + revisa
│   ├── adversarial-research.md        # /adversarial-research — deep research 3 provedores
│   ├── research-status.md             # /research-status — lista pesquisas
│   ├── research-synthesize.md         # /research-synthesize — sintetiza pesquisa
│   ├── pr.md                          # /pr — cria PR e faz merge
│   └── export-report.md              # /export-report — exporta resposta como .md
├── skills/                            # Skills globais
│   ├── react-feynman/SKILL.md         # Templates ReAct + Feynman
│   └── adversarial-research/          # Deep research com Gemini+Perplexity+OpenAI
│       ├── SKILL.md
│       └── runner.py
└── sync.sh                            # Script de sincronização
```

## Instalação

```bash
git clone https://github.com/alexlopespereira/dotclaude.git
cd dotclaude
chmod +x sync.sh
./sync.sh install
```

Isso copia tudo para `~/.claude/`, tornando os commands e skills disponíveis globalmente em qualquer projeto.

## Uso

Após a instalação, em qualquer projeto com Claude Code:

```
/planejar implementar autenticação OAuth2
/ciclo-completo migrar banco de dados para PostgreSQL
/adversarial-research impacto de LLMs na educação
/pr
```

## Sincronização

```bash
# Ver diferenças entre repo e ~/.claude/
./sync.sh status

# Após editar commands/skills em ~/.claude/, trazer mudanças para o repo
./sync.sh backup
git add -A && git commit -m "Atualizar commands/skills" && git push

# Após git pull (mudanças de outro lugar), instalar em ~/.claude/
./sync.sh install
```

## Pré-requisitos para adversarial-research

O `/adversarial-research` requer 3 API keys como variáveis de ambiente:

```bash
export GEMINI_API_KEY="..."
export PERPLEXITY_API_KEY="..."
export OPENAI_API_KEY="..."
```

E as dependências Python:
```bash
pip install google-genai openai requests
```
