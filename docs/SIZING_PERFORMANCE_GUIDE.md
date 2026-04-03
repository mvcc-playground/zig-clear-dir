# Sizing Performance Guide (`--with-size`)

Este documento resume as tecnicas aplicadas para deixar o calculo de tamanho muito mais rapido, especialmente no Windows.

## Objetivo

Reduzir latencia do `--with-size` mantendo seguranca no scan/remocao.

## Estrategias Que Deram Ganho Real

1. Separar modo de calculo:
- `--size-mode approx` (padrao): prioriza velocidade.
- `--size-mode exact`: prioriza precisao completa.
- `--size-mode hybrid`: estimativa rapida + refinamento exato.

2. Evitar `stat` por arquivo no caminho rapido do Windows:
- No `approx`, o tamanho dos arquivos vem direto da enumeracao Win32.
- Isso reduz syscall por arquivo e melhora muito em `node_modules`/`target`.

3. Controlar paralelismo de sizing:
- Menos workers simultaneos para sizing em Windows (evita thrash de disco).
- Discovery pode continuar rapido, mas sizing precisa limite mais conservador.

4. Reduzir ruido de log:
- Removido heartbeat por arquivo (`sizing working ... dirs/files`).
- Mantido progresso agregado (`sizing X/Y`) para leitura mais limpa.

## O Que Evitar

1. Rodar sempre `exact` sem necessidade:
- Em arvores grandes, o custo cresce muito.

2. Excesso de workers no sizing:
- Mais thread nem sempre = mais rapido (I/O satura).

3. Misturar scan e sizing sem controle de modo:
- Se o foco e decidir apagar rapido, use `approx`.

4. Achar que logs de progresso significam novos candidatos:
- Candidato e definido no discovery.
- Progresso de sizing so indica processamento interno do candidato.

## Recomendacao Pratica

1. Fluxo rapido para limpeza:
```powershell
zig build run -- --dir C:\Users\mathe\Downloads --with-size --size-mode approx
```

2. Quando precisar auditoria mais precisa:
```powershell
zig build run -- --dir C:\Users\mathe\Downloads --with-size --size-mode exact
```

3. Quando quiser resposta rapida + refinamento:
```powershell
zig build run -- --dir C:\Users\mathe\Downloads --with-size --size-mode hybrid
```

## Como Interpretar A Saida

- `total reclaimable (estimated)`: valor estimado (modo rapido).
- `total reclaimable (exact)`: valor calculado completamente.

## Checklist De Performance

1. Use `--size-mode approx` por padrao.
2. Use `--match-dir` e `--skip-dir` para reduzir escopo.
3. Use `--skip-path-regex` para evitar caminhos caros/desnecessarios.
4. Use `--no-progress` se quiser output mais limpo.
5. Troque para `exact` apenas quando necessario.
