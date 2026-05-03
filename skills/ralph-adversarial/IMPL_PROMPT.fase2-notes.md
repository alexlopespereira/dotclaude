<!-- ARQUIVO INFORMATIVO — NÃO É INJETADO NO PROMPT DO AGENTE. Se vê esse texto no prompt do Ralph, há bug no runner. -->

Este template assume execução serial. Fase 2 (story-level parallelism) exigirá coordenação de progress.txt e AGENTS.md (file lock ou append-com-pid). Princípios Karpathy (mudança mínima viável) podem mascarar colisões em fan-out — adaptar antes de Fase 2.
