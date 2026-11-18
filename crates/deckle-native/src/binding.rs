//! Camada fina do mlua. Converte `opts` de Lua para [`RenderOptions`] e [`RenderError`] para
//! erro de Lua. Toda a logica vive em `render.rs`; aqui nao ha decisao de render.
//!
//! O modulo nunca chama a API do Neovim (ADR-0001): so recebe valores Lua e devolve valores
//! Lua.
//!
//! # Formato do erro
//!
//! `render` e `render_ex` falham com `error(<string>, 0)`: o valor que o `pcall` devolve e uma
//! **string** de uma linha, sem posicao e sem traceback. Se o Rust devolvesse o `Err` direto, o
//! mlua o entregaria ao Lua como userdata, e `tostring` dele anexa um `stack traceback` que nao
//! serve para mostrar ao usuario. Por isso a funcao nativa devolve `(valor, nil)` ou
//! `(nil, msg)` e um wrapper Lua minusculo faz o `error`.
//!
//! # Duas funcoes de render
//!
//! * `render(src, opts?) -> string[]` e o contrato original da camada 1 e nao mudou: so as
//!   linhas. Quem a chama nao sabe se houve simplificacao.
//! * `render_ex(src, opts?) -> { lines, simplified?, cause? }` devolve as mesmas linhas mais o
//!   que o fallback de achatamento mudou (`simplified` e `"subgraphs"` ou
//!   `"composite states"`, ausente quando o desenho e fiel; `cause` e a mensagem do merman que
//!   o motivou). Foi uma segunda funcao, e nao um retorno extra de `render`, para a API
//!   existente continuar valendo para quem a usa (e para os mocks da suite Lua). O
//!   `render/mermaid.lua` usa `render_ex` quando o modulo a exporta e cai para `render` quando
//!   nao (modulo nativo de uma versao anterior do plugin).

use mlua::prelude::*;

use crate::render::{self, Charset, RenderError, RenderOptions};

/// Wrapper que transforma `(nil, msg)` em `error(msg, 0)`. Recebe a funcao nativa como `...`.
const RAISE_WRAPPER: &str = r#"
local raw = ...
return function(src, opts)
  local value, err = raw(src, opts)
  if value == nil then
    error(err, 0)
  end
  return value
end
"#;

/// Monta a tabela exportada por `require("deckle_native")`.
pub fn module(lua: &Lua) -> LuaResult<LuaTable> {
    let exports = lua.create_table()?;
    exports.set("render", raising(lua, lua.create_function(render_raw)?)?)?;
    exports.set(
        "render_ex",
        raising(lua, lua.create_function(render_ex_raw)?)?,
    )?;
    exports.set(
        "supported_types",
        lua.create_function(|_, ()| Ok(render::supported_types()))?,
    )?;
    exports.set(
        "version",
        lua.create_function(|_, ()| Ok(env!("CARGO_PKG_VERSION")))?,
    )?;
    Ok(exports)
}

/// Embrulha uma funcao nativa que devolve `(valor, nil)` ou `(nil, msg)` na que levanta erro.
fn raising(lua: &Lua, raw: LuaFunction) -> LuaResult<LuaFunction> {
    lua.load(RAISE_WRAPPER).set_name("=deckle_native").call(raw)
}

/// `render_raw(src, opts?) -> lines | (nil, msg)`. Nunca levanta erro de Lua por conta propria:
/// argumento do tipo errado tambem vira `(nil, msg)`.
fn render_raw(
    _: &Lua,
    (src, opts): (LuaValue, LuaValue),
) -> LuaResult<(Option<Vec<String>>, Option<String>)> {
    let result = parse_args(&src, &opts).and_then(|(src, opts)| render::render(&src, &opts));
    Ok(match result {
        Ok(lines) => (Some(lines), None),
        Err(err) => (None, Some(err.to_string())),
    })
}

/// `render_ex_raw(src, opts?) -> { lines, simplified?, cause? } | (nil, msg)`.
fn render_ex_raw(
    lua: &Lua,
    (src, opts): (LuaValue, LuaValue),
) -> LuaResult<(Option<LuaTable>, Option<String>)> {
    let result = parse_args(&src, &opts).and_then(|(src, opts)| render::render_ex(&src, &opts));
    match result {
        Ok(rendered) => {
            let table = lua.create_table()?;
            table.set("lines", rendered.lines)?;
            if let Some(simplified) = rendered.simplified {
                table.set("simplified", simplified.label())?;
            }
            if let Some(cause) = rendered.cause {
                table.set("cause", cause)?;
            }
            Ok((Some(table), None))
        }
        Err(err) => Ok((None, Some(err.to_string()))),
    }
}

fn parse_args(src: &LuaValue, opts: &LuaValue) -> Result<(String, RenderOptions), RenderError> {
    let src = match src {
        // Buffer do Neovim pode ter bytes invalidos em UTF-8. Perde-los e melhor do que recusar
        // o diagrama inteiro.
        LuaValue::String(s) => String::from_utf8_lossy(&s.as_bytes()).into_owned(),
        other => {
            return Err(RenderError::InvalidOption(format!(
                "src must be a string, got {}",
                other.type_name()
            )))
        }
    };
    let opts = match opts {
        LuaValue::Nil => RenderOptions::default(),
        LuaValue::Table(table) => parse_opts(table)?,
        other => {
            return Err(RenderError::InvalidOption(format!(
                "opts must be a table or nil, got {}",
                other.type_name()
            )))
        }
    };
    Ok((src, opts))
}

fn parse_opts(table: &LuaTable) -> Result<RenderOptions, RenderError> {
    let mut opts = RenderOptions::default();

    if let Some(width) = get::<i64>(table, "width")? {
        opts.width = positive(width, "width")?;
    }
    if let Some(max) = get::<i64>(table, "max_src_lines")? {
        opts.max_src_lines = positive(max, "max_src_lines")?;
    }
    if let Some(charset) = get::<String>(table, "charset")? {
        opts.charset = Charset::parse(&charset)?;
    }
    opts.diagram_ty = get::<String>(table, "diagram_ty")?;
    Ok(opts)
}

fn get<T: FromLua>(table: &LuaTable, key: &str) -> Result<Option<T>, RenderError> {
    table
        .get::<Option<T>>(key)
        .map_err(|err| RenderError::InvalidOption(format!("opts.{key}: {err}")))
}

fn positive(value: i64, key: &str) -> Result<usize, RenderError> {
    usize::try_from(value)
        .ok()
        .filter(|n| *n >= 1)
        .ok_or_else(|| {
            RenderError::InvalidOption(format!("opts.{key} must be at least 1, got {value}"))
        })
}
