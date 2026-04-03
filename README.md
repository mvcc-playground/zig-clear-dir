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

Atalhos do prompt:

- `y` => apaga item atual
- `n` => pula item atual
- `y-all` => apaga item atual e todos os restantes

### Incluir calculo de tamanho (mais lento)

```powershell
zig build run -- --dir C:\Users\mathe\projetos --with-size
```

A saida mostra tamanhos em formato humano e em bytes:

- `13.20 GB (14171541246 bytes)`

## Comandos Explicitos

### scan (nao remove)

```powershell
zig build run -- scan --root C:\Users\mathe\projetos
```

Opcoes principais:

- `--root <path>` (pode repetir)
- `--match-dir <nome>` (pode repetir)
- `--skip-dir <nome>` (pode repetir)
- `--workers auto|N`
- `--with-size`
- `--no-progress`
- `--snapshot <path>`
- `--no-snapshot`

### apply (remove via snapshot)

```powershell
zig build run -- apply --snapshot C:\temp\scan.json --confirm REMOVE
```

Dry-run:

```powershell
zig build run -- apply --snapshot C:\temp\scan.json --confirm REMOVE --dry-run
```

## Snapshot

- Caminho padrao: `HOME/.rm-folders/snapshots/<timestamp>.json`
- No modo interativo com `zig build run`, por padrao nao salva snapshot automaticamente.
- Para forcar salvar: use `--snapshot <path>`.
- Para desabilitar explicitamente: `--no-snapshot`.

## Performance

- Discovery rapido por padrao.
- Calculo de tamanho e opcional (`--with-size`).
- Adaptador de tamanho por SO (`platform.size`) para otimizar por plataforma.
- Logs de progresso durante discovery e sizing.

## Seguranca

- Nao segue symlink/junction para traversal indevido.
- Bloqueia remocao perigosa (ex.: raiz de volume).
- Remove somente caminhos descobertos/selecionados.
- Trata `AccessDenied` com skip seguro durante scan.

## Defaults de Match/Skip

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
.\zig-out\bin\rm-folders.exe --dir C:\Users\mathe\projetos --with-size
```