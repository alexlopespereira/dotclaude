# systemd/ — unit + launcher das VMs UTM

Artefatos capturados **verbatim** das VMs UTM `192.0.2.11` (VM1) e
`192.0.2.12` (VM2), idênticos entre as duas no momento da captura.

## Arquivos

- **`claude-code.service`** — unit systemd. Origem real:
  `/etc/systemd/system/claude-code.service` em ambas as VMs (capturada via
  `systemctl cat`, sem a linha de comentário de path que o `systemctl`
  prefixa). Inicia uma sessão tmux interativa do Claude por repo no boot.
- **`claude-sessions.sh`** — launcher. Origem real:
  `/home/dev/.local/bin/claude-sessions.sh` em ambas as VMs
  (md5 `f8faf7539e6463e0143ee8fa3aa698a2`). Auto-descobre os slots `*-1` em
  `~/Projects/checkouts` e sobe uma sessão tmux por repo, com locale UTF-8
  PT-BR forçado (o systemd unit não herda `LANG`/`LC_*`).

## ⚠️ Paths hardcoded — válidos só nas VMs

A unit referencia caminhos absolutos `/home/dev/...` (`WorkingDirectory`,
`ExecStart`, `Environment=HOME=/home/dev`, `PATH=/home/dev/.bun/bin:...`).
Esses paths só existem nas VMs Ubuntu — **não** rode esta unit no laptop
macOS. A fase root de `bin/vm-provision.sh` (US-02) tem um guard
(`uname == Linux` e usuário `dev`) que aborta antes de qualquer mutação
justamente para impedir instalação acidental no host.

## Instalação

A cópia para `/etc/systemd/system/claude-code.service` (e o
`daemon-reload`) é feita pela **fase root** de `bin/vm-provision.sh`
(US-02), só quando `cmp` detecta diferença entre o arquivo versionado aqui
e o instalado na VM. Estes arquivos são a **fonte da verdade**; as VMs são
o destino.
