# Performance — decisões de projeto

Este documento explica as decisões de performance do Clear Dev Cache nas duas
operações mais pesadas: **scan** (descoberta de pastas-alvo) e **remoção**
(deleção das pastas selecionadas).

---

## Scan

### Dois modos de operação

| Modo | O que faz | Quando usar |
|------|-----------|-------------|
| **Fast** | Encontra as pastas-alvo, reporta tamanho `0` para todas | Quero ver o que existe rapidamente |
| **Full** | Encontra as pastas-alvo e calcula o tamanho real de cada uma | Quero saber quanto vou liberar antes de deletar |

A distinção existe porque calcular o tamanho de uma `node_modules` grande pode
levar vários segundos — e para quem quer só listar o que está no disco, esse
custo é desnecessário.

### Poda precoce de subárvores (pruning)

Quando o scanner encontra uma pasta que bate em um dos targets (ex.:
`node_modules`), ele **não desce dentro dela**. Isso é feito de formas
diferentes dependendo do backend:

- **Windows** (`discover_windows_native`): a pasta encontrada vai para `out`,
  *não* para o `stack`. O stack só recebe filhos que não são targets.
- **WalkDir** (`discover_walkdir`): chama `iter.skip_current_dir()` logo após
  registrar o match.

Sem essa poda, o scanner entraria em `node_modules` e processaria todas as
centenas de subpastas dentro dela — trabalho inútil, pois já vamos deletar o
diretório inteiro.

### Cálculo de tamanhos em paralelo (Full mode)

Depois de coletar todos os candidatos, o modo Full precisa medir o tamanho de
cada um. Isso é feito com `rayon::par_iter`, que distribui os `dir_size` em
paralelo entre os núcleos disponíveis:

```rust
let out = pending
    .into_par_iter()
    .map(|p| {
        let size = dir_size(&p.path)?;
        // ...
    })
    .collect::<Result<Vec<_>>>()?;
```

Para um repositório monorepo com 20 `node_modules` distintos, todos são medidos
ao mesmo tempo em vez de sequencialmente.

### Exclusões de sistema

Antes de descer em qualquer diretório, o scanner verifica se ele está na lista
de caminhos do sistema operacional (ex.: `C:\Windows`, `/System`, `/usr`). Essa
verificação é O(1) por prefixo e evita que o scanner desperdice tempo — e
potencialmente cause erros de permissão — em pastas que nunca conterão código
de desenvolvimento.

A lista é construída em `crates/platform/src/system_exclusions.rs` com blocos
`#[cfg(...)]` por OS. Veja [`docs/windows/scan-native-api.md`](windows/scan-native-api.md)
para os detalhes do Windows.

---

## Remoção

### O problema do double-walk (resolvido)

A versão ingênua do cleaner fazia:

```
para cada pasta selecionada:
    1. dir_size(pasta)       ← walk recursivo para contar bytes
    2. remove_dir_all(pasta) ← walk recursivo para deletar
```

Para um `node_modules` com 100 000 arquivos, isso significava **200 000 chamadas
de stat desnecessárias** — o dobro do necessário. O modo Full já tinha medido
tudo durante o scan; a remoção estava repetindo o trabalho.

### A solução: size hint no CleanRequest

`CleanRequest` carrega os tamanhos já conhecidos em `selected_bytes: Vec<u64>`,
paralelo a `selected_paths`. O cleaner usa esse valor diretamente e **só chama
`dir_size` quando o tamanho é 0** (sinal de "desconhecido", que ocorre no Fast
mode):

```rust
let bytes = match size_hint.get(&path).copied() {
    Some(b) if b > 0 => b,           // usa o valor do scan — sem dir_size
    _                => dir_size(&path).unwrap_or(0),  // Fast mode fallback
};
```

**Impacto**: em Full mode, a remoção passa de 3 traversals por pasta (scan +
dir_size + remove) para 2 (scan + remove).

### Ordenação deepest-first

Antes de deletar, os caminhos são ordenados do mais profundo para o mais raso
(pela contagem de bytes no `OsStr`, que cresce com a profundidade):

```rust
paths.sort_by_key(|p| usize::MAX - p.as_os_str().len());
```

Isso garante que, se o usuário selecionou tanto `proj/node_modules` quanto
`proj/node_modules/algum-pkg/node_modules`, o filho é deletado primeiro. Quando
o pai é processado em seguida, ele ainda existe (só perdeu um subdiretório) e
`remove_dir_all` termina o serviço sem erros.

### Remoção sequencial

A remoção é propositalmente sequencial — não usa rayon. As razões:

1. `remove_dir_all` é limitado pela largura de banda do disco, não pela CPU.
   Paralelizar escritas no mesmo volume raramente acelera e pode fragmentar.
2. Ordenar por profundidade para evitar conflitos pai-filho fica trivial em
   código sequencial. Com rayon seria necessário particionar em grupos de
   "seguro para deletar em paralelo", o que é complexo sem ganho claro.

---

## Resumo por plataforma

| Otimização | Windows | macOS / Linux |
|---|---|---|
| API nativa de listagem | `FindFirstFileExW` + `FIND_FIRST_EX_LARGE_FETCH` | WalkDir (libstd) |
| Poda de subárvores | Stack DFS, filho não entra no stack | `iter.skip_current_dir()` |
| Tamanho paralelo (Full) | rayon | rayon |
| Size hint na remoção | ✓ | ✓ |
| Ordenação deepest-first | ✓ | ✓ |

Para os detalhes específicos do Windows, veja
[`docs/windows/scan-native-api.md`](windows/scan-native-api.md).
