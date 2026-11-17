return {
  {
    kind = "paragraph",
    spans = { { kind = "text", text = "Parágrafo antes." } },
    src_start = 0,
    src_end = 1,
  },
  { kind = "rule", src_start = 2, src_end = 3 },
  { kind = "rule", src_start = 4, src_end = 5 },
  {
    kind = "html",
    lines = { '<div class="x">', "  <p>html cru</p>", "</div>" },
    src_start = 6,
    src_end = 9,
  },
  { kind = "html", lines = { "<!-- comentário -->" }, src_start = 10, src_end = 11 },
  {
    kind = "paragraph",
    spans = { { kind = "text", text = "Parágrafo depois." } },
    src_start = 12,
    src_end = 13,
  },
}
