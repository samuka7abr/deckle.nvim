//! `deckle-native`: camada 1 do deckle.nvim. Renderiza Mermaid em arte de texto.
//!
//! - `render`: logica pura, testavel com `cargo test` sem Lua (ADR-0001).
//! - `binding`: camada fina do mlua que exporta o modulo Lua `deckle_native`.
//!
//! Contrato completo em `docs/architecture.md`, secao 5.

mod binding;
mod flatten;
mod render;

#[cfg(test)]
mod render_tests;

use mlua::prelude::*;

/// Ponto de entrada de `require("deckle_native")`. O nome da funcao vira o simbolo
/// `luaopen_deckle_native`, e por isso o arquivo instalado precisa se chamar
/// `deckle_native.so`, sem o prefixo `lib` que o cargo coloca.
#[mlua::lua_module]
fn deckle_native(lua: &Lua) -> LuaResult<LuaTable> {
    binding::module(lua)
}
