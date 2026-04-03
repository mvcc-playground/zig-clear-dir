# rm-folders

CLI em Zig para localizar e remover pastas de build/cache com foco em seguranca, velocidade e baixo uso de RAM.

## Status

Versao beta (pre-1.0.0).

## Requisitos

- Zig `0.15.2`
- Windows/macOS/Linux

## Build

```powershell
zig build -Doptimize=ReleaseFast
```

Binario gerado:

```text
zig-out/bin/rm-folders.exe
```

## Uso Rapido

### Modo padrao interativo (recomendado)

Escaneia e pergunta na hora se quer apagar:

```powershell
# diretorio atual
zig build run --

# diretorio especifico
zig build run -- --dir C:\Users\mathe\projetos
```

Fluxo do prompt de remocao:

- Primeiro pergunta modo: `all/a`, `none/n`, `each/e`.
- Em `each`:
- `y` => apaga item atual
- `n` => pula item atual
- `y-all` => apaga item atual e todos os restantes

### Calculo de tamanho exato

```powershell
zig build run -- --dir C:\Users\mathe\projetos
```

A saida sempre mostra tamanhos exatos em formato humano e em bytes:

- `13.20 GB (14171541246 bytes)`

## Opcoes Principais

- `--dir <path>` ou `--path <path>`: diretorio alvo do scan.
- `--match-dir <nome>`: nomes de pasta para procurar.
- `--skip-dir <nome>`: nomes de pasta para ignorar.
- `--no-default-rules`: nao carregar regras padrao embutidas.
- `--skip-path-regex <pattern>`: excluir por regex-lite de caminho (suporta `.*`).
- `--no-skip-dot-dirs`: permite entrar em pastas que comecam com ponto.
- `--workers auto|N`
- `--delete-workers auto|N`
- `--no-progress`
- `--delete-workers auto|N`

Voce pode repetir `--match-dir` e `--skip-dir`, ou passar lista por virgula:

```powershell
zig build run -- --dir C:\Users\mathe\projetos --match-dir node_modules,target,dist --skip-dir AppData,.git --skip-path-regex ".*/\\..*"
```

Exemplo sem defaults embutidos:

```powershell
zig build run -- --dir C:\Users\mathe\projetos --no-default-rules --match-dir target,node_modules --skip-dir .git,.cache
```

## Performance

- Discovery rapido por padrao.
- Calculo de tamanho exato sempre ativo.
- Adaptador de tamanho por SO (`platform.size`) para otimizar por plataforma.
- Logs de progresso durante discovery e sizing.

## Seguranca

- Nao segue symlink/junction para traversal indevido.
- Bloqueia remocao perigosa (ex.: raiz de volume).
- Remove somente caminhos descobertos/selecionados.
- Trata `AccessDenied` com skip seguro durante scan.

## Defaults de Match/Skip

Arquivo de configuracao padrao embutido no executavel:

- `src/core/default_rules.zig`

Match padrao:

- `node_modules`
- `target`

Skip padrao:

- `.git`, `.hg`, `.svn`
- `System Volume Information`, `$RECYCLE.BIN`
- `.zig-cache`, `zig-out`
- `AppData`

## Dica para Windows

Se `zig build run` falhar por problema intermitente de processo/pipe no ambiente, use o binario direto:

```powershell
zig build -Doptimize=ReleaseFast
.\zig-out\bin\rm-folders.exe --dir C:\Users\mathe\projetos
```
