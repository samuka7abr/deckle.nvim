return {
  {
    kind = "table",
    align = { "left", "center", "right" },
    header = {
      { { kind = "text", text = "Esquerda" } },
      { { kind = "text", text = "Centro" } },
      { { kind = "text", text = "Direita" } },
    },
    rows = {
      {
        { { kind = "text", text = "a" } },
        { { kind = "text", text = "b" } },
        { { kind = "text", text = "c" } },
      },
      {
        { { kind = "strong", children = { { kind = "text", text = "x" } } } },
        { { kind = "code", text = "y" } },
        { { kind = "link", children = { { kind = "text", text = "z" } }, href = "u" } },
      },
      { {}, { { kind = "text", text = "vazio" } }, {} },
      { { { kind = "text", text = "curta" } } },
      {
        { { kind = "text", text = "日本語" } },
        { { kind = "text", text = "😀" } },
        { { kind = "text", text = "ñ" } },
      },
    },
    src_start = 0,
    src_end = 7,
  },
  {
    kind = "table",
    align = {},
    header = { { { kind = "text", text = "Só" } }, { { kind = "text", text = "cabeçalho" } } },
    rows = {},
    src_start = 8,
    src_end = 10,
  },
  {
    kind = "table",
    align = {},
    header = { { { kind = "text", text = "sem" } }, { { kind = "text", text = "alinhamento" } } },
    rows = {
      {
        { { kind = "text", text = "escape | barra" } },
        { { kind = "text", text = "ok" } },
      },
    },
    src_start = 11,
    src_end = 14,
  },
}
