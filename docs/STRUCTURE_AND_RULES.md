# Structure And Rules

Este documento descreve como o projeto esta organizado e como as regras de scan/exclusao funcionam.

## Visao Geral

Fluxo atual:

1. Descobrir diretorios candidatos (match/skip).
2. Opcionalmente calcular tamanho (`--with-size`).
3. Mostrar lista.
4. Prompt interativo com modo inicial (`all|none|each`) e, se `each`, selecao por item (`y`, `n`, `y-all`).

Nao existe mais modo separado `scan/apply` para uso normal do CLI. O fluxo principal e direto/interativo.

## Estrutura de Modulos

- `src/main.zig`
: Entrada da CLI, execucao do fluxo interativo e prompt de confirmacao.

- `src/core/config.zig`
: Parse de argumentos e defaults de runtime (roots, flags, workers, etc.).

- `src/core/default_rules.zig`
: Regras padrao embutidas no executavel (`match_dirs`, `skip_dirs`, `skip_dot_dirs`, regexes padrao).

- `src/core/string_lists.zig`
: Helpers de parsing de listas (inclui CSV por virgula), flags e utilitarios de memoria para slices de strings.

- `src/core/rules.zig`
: Normalizacao e decisao de regras (`shouldMatchDir`, `shouldSkipDir`, `shouldSkipPath`).

- `src/core/regex_lite.zig`
: Matcher leve para padroes de caminho com suporte principal a `.*`.

- `src/core/scanner.zig`
: Descoberta de candidatos, aplicacao de regras, progresso e orquestracao do sizing.

- `src/platform/*`
: Adapter de plataforma para filesystem e calculo de tamanho por SO.

## Regras de Scan

### Match de diretorio (`--match-dir`)

Define quais nomes de pasta sao candidatos a remocao.

Exemplos:

- `--match-dir target`
- `--match-dir node_modules,target,dist`

### Skip por nome (`--skip-dir`)

Ignora entrada por nome exato (comparacao case-insensitive no Windows).

Exemplos:

- `--skip-dir .git`
- `--skip-dir .git,AppData`

### Skip por caminho (`--skip-path-regex`)

Ignora por padrao regex-lite no caminho completo. Suporte principal:

- `.*` = coringa de qualquer sequencia.
- escapes simples (`\\.` `\\/` `\\\\`) para literal.

Exemplo util para pular qualquer pasta oculta no caminho:

- `--skip-path-regex ".*/\\..*"`

### Skip de dot dirs

Por padrao, diretorios iniciados por `.` sao ignorados.

- para manter default: nao passar nada
- para permitir entrada nesses diretorios: `--no-skip-dot-dirs`

### Desligar defaults embutidos

- `--no-default-rules`

Quando usado, regras padrao embutidas nao sao carregadas; voce define tudo por flags.

Nao existe modo separado de snapshot/apply no fluxo atual.

## Prompt Interativo

Durante a remocao:

- Escolha inicial:
- `all`/`a`: remove todos os candidatos listados.
- `none`/`n`: nao remove nada.
- `each`/`e`: pergunta item por item.
- No modo `each`:
- `y`: remove item atual
- `n`: pula item atual
- `y-all`: remove item atual e todos os restantes

## Observacoes de Performance

- Sem `--with-size`, o scan e mais rapido (nao calcula bytes recursivos).
- Com `--with-size`, o tamanho exato exige varredura de arquivos.
- Logs de progresso ajudam a acompanhar discovery/sizing.
