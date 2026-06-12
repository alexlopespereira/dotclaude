#!/usr/bin/env bash
# vm-common.sh — fonte única do mapping VM→IP das VMs UTM (e do user padrão).
#
# O QUE FAZ: define vm_ip <1|2> (ecoa o IP; rc=1 para id desconhecido) e
# VM_COMMON_USER. Antes, o mapping vivia duplicado em vm-oauth.sh e
# vm-provision.sh — mudança de IP exigia editar N arquivos em sincronia.
#
# QUANDO USAR: source deste arquivo em scripts que falam com as VMs e rodam
# no host (laptop) — bin/ e também os launchers da raiz (vm1.sh, vm2.sh,
# vm-morning.sh, vm-paste.sh, consumidores desde US-10). Scripts que viajam
# sozinhos pra VM via scp (ex.: vm-provision.sh) só podem depender da lib em
# ramos host-side.

# shellcheck disable=SC2034  # consumida por quem dá source (ex.: vm-oauth.sh: VM_USER="$VM_COMMON_USER")
VM_COMMON_USER="dev"

vm_ip() { # 1|2 → ecoa IP; desconhecido → rc 1
  case "${1:-}" in
    1) printf '192.0.2.11' ;;
    2) printf '192.0.2.12' ;;
    *) return 1 ;;
  esac
}
