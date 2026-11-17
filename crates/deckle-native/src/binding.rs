//! Camada fina do mlua. Converte `opts` de Lua para [`RenderOptions`] e [`RenderError`] para
//! erro de Lua. Toda a logica vive em `render.rs`; aqui nao ha decisao de render.
//!
//! O modulo nunca chama a API do Neovim (ADR-0001): so recebe valores Lua e devolve valores
//! Lua.
//!
//! # Formato do erro
//!
//! `render` falha com `error(<string>, 0)`: o valor que o `pcall` devolve e uma **string** de
//! uma linha, sem posicao e sem traceback. Se o Rust devolvesse o `Err` direto, o mlua o
//! entregaria ao Lua como userdata, e `tostring` dele anexa um `stack traceback` que nao serve
//! para mostrar ao usuario. Por isso a funcao nativa devolve `(lines, nil)` ou `(nil, msg)` e
//! um wrapper Lua minusculo faz o `error`.

use mlua::prelude::*;

use crate::render::{self, Charset, RenderError, RenderOptions};

/// Wrapper que transforma `(nil, msg)` em `error(msg, 0)`. Recebe a funcao nativa como `...`.
const RENDER_WRAPPER: &str = r#"
local raw = ...
return function(src, opts)
  local lines, err = raw(src, opts)
  if lines == nil then
    error(err, 0)
  end
  return lines
end
"#;

/// Monta a tabela exportada por `require("deckle_native")`.
pub fn module(lua: &Lua) -> LuaResult<LuaTable> {
    let exports = lua.create_table()?;
    let raw = lua.create_function(render_raw)?;
    let render: LuaFunction = lua
        .load(RENDER_WRAPPER)
        .set_name("=deckle_native")
        .call(raw)?;
    exports.set("render", render)?;
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
