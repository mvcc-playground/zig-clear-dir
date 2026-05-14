# Windows — API nativa de scan de diretórios

No Windows, o scanner usa `FindFirstFileExW` / `FindNextFileW` diretamente via
`windows-sys` em vez da crate `walkdir`. Este documento explica por que essa
escolha foi feita, o que cada flag significa, e o que seria necessário para
manter ou substituir essa implementação.

**Arquivo de implementação:** `crates/platform/src/fs_backend.rs`  
**Função:** `discover_windows_native` (compilada apenas em `#[cfg(windows)]`)

---

## Por que não usar WalkDir no Windows?

`walkdir` é portável e correta, mas internamente usa `std::fs::read_dir`, que
por sua vez chama `FindFirstFileW` (sem o sufixo `Ex`) e `FindNextFileW` com
configurações conservadoras. Isso deixa duas otimizações disponíveis na mesa:

1. **`FindExInfoBasic`** — suprime o campo `cAlternateFileName` (o nome curto
   estilo 8.3, ex.: `PROGRA~1`). Quando esse campo não é necessário, o kernel
   pula a geração do nome curto, economizando trabalho interno no NTFS.

2. **`FIND_FIRST_EX_LARGE_FETCH`** — instrui o kernel a pré-alocar um buffer
   maior para devolver múltiplas entradas de diretório de uma vez. Reduz o
   número de round-trips kernel/userspace, o que é especialmente perceptível em
   diretórios com centenas de entradas (ex.: `node_modules`).

Para volumes com muitos arquivos, a combinação dessas duas flags pode reduzir o
tempo de listagem em **30–50%** comparado a `FindFirstFileW` padrão.

---

## Flags e parâmetros explicados

```rust
FindFirstFileExW(
    pattern.as_ptr(),        // "C:\caminho\*\0" em UTF-16
    FindExInfoBasic,         // não preencher cAlternateFileName
    &mut data as *mut _,     // WIN32_FIND_DATAW: recebe os dados da entrada
    FindExSearchNameMatch,   // filtrar por nome (o padrão normal)
    std::ptr::null(),        // sem filtro adicional (usado com outros modos de busca)
    FIND_FIRST_EX_LARGE_FETCH, // buffer grande → menos syscalls
)
```

### `FindExInfoBasic` vs `FindExInfoStandard`

| Flag | `cAlternateFileName` preenchido? | Custo |
|------|----------------------------------|-------|
| `FindExInfoStandard` | Sim | NTFS gera o nome 8.3 por entrada |
| `FindExInfoBasic` | Não | Campo ignorado, menos trabalho do FS |

Neste scanner o nome curto nunca é usado — o caminho completo já vem em
`cFileName`. Usar `FindExInfoBasic` é seguro e mais rápido.

### `FIND_FIRST_EX_LARGE_FETCH`

Disponível a partir do Windows Server 2008 R2 / Windows 7. Quando ativo, o
kernel reserva um buffer maior na primeira chamada e usa para retornar múltiplos
registros por `FindNextFileW`, evitando mais alternâncias entre modos
kernel/usuário. O efeito é especialmente notável em SSDs NVMe onde a latência
por syscall, e não a largura de banda, é o gargalo.

---

## Travessia DFS com stack explícito

Em vez de recursão (que pode estourar a pilha em árvores muito profundas) ou
iteradores do WalkDir, usamos um stack explícito em `Vec`:

```
stack = [raiz]

loop:
    current = stack.pop()
    abrir current com FindFirstFileExW
    para cada entrada de diretório:
        se é um target (node_modules, dist, ...):
            adicionar a `out`          ← não vai ao stack (poda)
        senão:
            adicionar ao stack         ← será visitado depois
```

A poda é a parte crítica: quando uma pasta bate em uma das regras, ela vai
direto para `out` e **seus filhos nunca são visitados**. Sem isso, o scanner
entraria em `node_modules` e percorreria todas as suas subpastas, gerando
trabalho inútil.

---

## Filtragem de reparse points

```rust
let is_reparse = (attrs & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
if is_dir && !is_reparse && !is_system_protected_name(&name) {
    // processar...
}
```

Reparse points incluem symlinks, junction points e volume mount points. Seguir
um symlink poderia:

- Criar um loop infinito (`A → B → A`)
- Sair da árvore do usuário e entrar em caminhos do sistema
- Deletar arquivos fora do `scan_root` durante a remoção

Por isso todo entry com `FILE_ATTRIBUTE_REPARSE_POINT` é ignorado.

---

## Nomes de sistema protegidos (`is_system_protected_name`)

Além das exclusões por prefixo de caminho (veja `system_exclusions.rs`), o
Windows tem pastas com nomes reservados que aparecem em **qualquer drive** e não
têm um caminho absoluto fixo:

| Nome | O que é |
|------|---------|
| `$Recycle.Bin` | Lixeira de cada drive |
| `System Volume Information` | Metadados NTFS e pontos de restauração |
| `Recovery` | Partição/diretório de recuperação do Windows |
| `WindowsApps` | Apps instalados pela Microsoft Store |

A função `is_system_protected_name` faz a checagem case-insensitive antes de
qualquer match de target ou push no stack.

---

## Dependência de compilação

`windows-sys` está declarada **apenas** como dependência de target Windows no
`platform/Cargo.toml`:

```toml
[target.'cfg(windows)'.dependencies]
windows-sys = { version = "0.60", features = [
    "Win32_Foundation",
    "Win32_Storage_FileSystem",
] }
```

Em macOS ou Linux, esse bloco inteiro não é compilado. O código de
`discover_windows_native` fica atrás de `#[cfg(windows)]` e nunca aparece no
binário de outras plataformas.

---

## Como substituir ou estender

Se no futuro for necessário usar outra API de listagem no Windows (ex.:
`NtQueryDirectoryFile`, que é ainda mais baixo nível e mais rápida), basta
substituir o corpo de `discover_windows_native`. A assinatura da função e o tipo
`PendingCandidate` que ela retorna não mudam — o restante do pipeline (rayon,
size hint, cleaner) não precisa saber como a descoberta foi feita.
