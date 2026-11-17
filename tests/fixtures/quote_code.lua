return {
  {
    kind = "quote",
    children = {
      {
        kind = "paragraph",
        spans = { { kind = "text", text = "citação simples\nque continua aqui" } },
        src_start = 0,
        src_end = 2,
      },
    },
    src_start = 0,
    src_end = 2,
  },
  {
    kind = "quote",
    children = {
      {
        kind = "paragraph",
        spans = {
          { kind = "text", text = "Citação com " },
          { kind = "strong", children = { { kind = "text", text = "negrito" } } },
        },
        src_start = 3,
        src_end = 4,
      },
      {
        kind = "list",
        items = {
          {
            children = {},
            spans = { { kind = "text", text = "item na citação" } },
            src_start = 5,
            src_end = 6,
          },
          {
            children = {},
            spans = { { kind = "text", text = "outro item" } },
            src_start = 6,
            src_end = 7,
          },
        },
        ordered = false,
        src_start = 5,
        src_end = 7,
      },
      {
        kind = "quote",
        children = {
          {
            kind = "paragraph",
            spans = { { kind = "text", text = "citação aninhada" } },
            src_start = 8,
            src_end = 9,
          },
        },
        src_start = 8,
        src_end = 9,
      },
    },
    src_start = 3,
    src_end = 9,
  },
  {
    kind = "code",
    lang = "rust",
    lines = { "fn main() {", '    println!("oi");', "}" },
    src_start = 10,
    src_end = 15,
  },
  { kind = "code", lines = { "sem linguagem" }, src_start = 16, src_end = 19 },
  { kind = "code", lang = "python", lines = { "print(1)" }, src_start = 20, src_end = 23 },
  {
    kind = "code",
    lines = { "bloco indentado", "com duas linhas" },
    src_start = 24,
    src_end = 26,
  },
  {
    kind = "paragraph",
    spans = { { kind = "text", text = "Depois do código." } },
    src_start = 27,
    src_end = 28,
  },
}
