return {
  {
    kind = "heading",
    level = 1,
    spans = { { kind = "text", text = "Título" } },
    src_start = 0,
    src_end = 1,
  },
  {
    kind = "paragraph",
    spans = { { kind = "text", text = "Primeira linha\nsegunda linha" } },
    src_start = 2,
    src_end = 4,
  },
  {
    kind = "list",
    items = {
      {
        children = {},
        spans = { { kind = "text", text = "item um\ncontinuação do item" } },
        src_start = 5,
        src_end = 7,
      },
      {
        children = {
          {
            kind = "list",
            items = {
              {
                children = {},
                spans = { { kind = "text", text = "sub item" } },
                src_start = 8,
                src_end = 9,
              },
            },
            ordered = false,
            src_start = 8,
            src_end = 9,
          },
        },
        spans = { { kind = "text", text = "item dois" } },
        src_start = 7,
        src_end = 9,
      },
    },
    ordered = false,
    src_start = 5,
    src_end = 9,
  },
  {
    kind = "quote",
    children = {
      {
        kind = "paragraph",
        spans = { { kind = "text", text = "citação\nem duas linhas" } },
        src_start = 10,
        src_end = 12,
      },
    },
    src_start = 10,
    src_end = 12,
  },
  { kind = "code", lang = "lua", lines = { "local x = 1" }, src_start = 13, src_end = 16 },
  { kind = "code", lines = { "indentado" }, src_start = 17, src_end = 18 },
  {
    kind = "table",
    align = {},
    header = { { { kind = "text", text = "a" } }, { { kind = "text", text = "b" } } },
    rows = { { { { kind = "text", text = "1" } }, { { kind = "text", text = "2" } } } },
    src_start = 19,
    src_end = 22,
  },
  { kind = "rule", src_start = 23, src_end = 24 },
  { kind = "html", lines = { "<div>", "html", "</div>" }, src_start = 25, src_end = 28 },
  {
    kind = "heading",
    level = 2,
    spans = { { kind = "text", text = "Setext" } },
    src_start = 29,
    src_end = 31,
  },
}
