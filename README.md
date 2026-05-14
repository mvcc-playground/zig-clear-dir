# clear-dev-cache (Rust + Slint)

Aplicativo desktop para scan e limpeza de lixo de build/cache com arquitetura SOLID, sem CLI como produto principal.

## Stack

- Rust `edition 2024`
- Slint UI
- Arquitetura em camadas (`domain`, `application`, `platform`, `preferences`, `desktop`)

## Rodar

```powershell
cargo run -p clear-dev-cache-desktop
```

## Estrutura

- `crates/domain`: entidades e regras de negocio (targets de limpeza)
- `crates/application`: casos de uso e contratos (ports)
- `crates/platform`: scan e remocao no filesystem
- `crates/preferences`: estado de aprendizado local em JSON
- `apps/desktop`: UI Slint e orquestracao final

## Aprendizado de uso

O app salva estado local para melhorar experiencia a cada execucao:

- regras customizadas de lixo
- diretorios recentes
- estatisticas de limpezas

Arquivo de estado local:

- `%LOCALAPPDATA%/clear-dev-cache/learning.json` (Windows)
