return {
  {
    kind = "paragraph",
    spans = {
      { kind = "text", text = "Texto com " },
      { kind = "strong", children = { { kind = "text", text = "negrito" } } },
      { kind = "text", text = ", " },
      { kind = "emphasis", children = { { kind = "text", text = "itálico" } } },
      { kind = "text", text = " e " },
      { kind = "code", text = "código" },
      { kind = "text", text = " no meio." },
    },
    src_start = 0,
    src_end = 1,
  },
  {
    kind = "paragraph",
    spans = {
      { kind = "text", text = "Aninhado: " },
      {
        kind = "strong",
        children = {
          { kind = "text", text = "negrito com " },
          { kind = "emphasis", children = { { kind = "text", text = "itálico" } } },
          { kind = "text", text = " dentro" },
        },
      },
      { kind = "text", text = " e " },
      {
        kind = "emphasis",
        children = { { kind = "strong", children = { { kind = "text", text = "ambos" } } } },
      },
      { kind = "text", text = "." },
    },
    src_start = 2,
    src_end = 3,
  },
  {
    kind = "paragraph",
    spans = {
      { kind = "text", text = "Crase no código: " },
      { kind = "code", text = "a ` b" },
      { kind = "text", text = " e " },
      { kind = "code", text = "espaço" },
      { kind = "text", text = "." },
    },
    src_start = 4,
    src_end = 5,
  },
  {
    kind = "paragraph",
    spans = {
      { kind = "text", text = "Links: " },
      {
        kind = "link",
        children = { { kind = "text", text = "inline" } },
        href = "https://example.com/a?b=c",
      },
      { kind = "text", text = ", " },
      {
        kind = "link",
        children = { { kind = "text", text = "com título" } },
        href = "https://example.com/x y",
      },
      { kind = "text", text = ", " },
      { kind = "link", children = { { kind = "text", text = "vazio" } }, href = "" },
      { kind = "text", text = ", " },
      {
        kind = "link",
        children = { { kind = "text", text = "ref" } },
        href = "https://example.com/r1",
      },
      { kind = "text", text = ", " },
      {
        kind = "link",
        children = { { kind = "text", text = "colapsado" } },
        href = "https://example.com/c",
      },
      { kind = "text", text = ", " },
      {
        kind = "link",
        children = { { kind = "text", text = "atalho" } },
        href = "https://example.com/a",
      },
      { kind = "text", text = " e [sem definição]." },
    },
    src_start = 6,
    src_end = 7,
  },
  {
    kind = "paragraph",
    spans = {
      { kind = "text", text = "Autolinks: " },
      {
        kind = "link",
        children = { { kind = "text", text = "https://example.com" } },
        href = "https://example.com",
      },
      { kind = "text", text = " e " },
      {
        kind = "link",
        children = { { kind = "text", text = "fulano@example.com" } },
        href = "mailto:fulano@example.com",
      },
      { kind = "text", text = "." },
    },
    src_start = 8,
    src_end = 9,
  },
  {
    kind = "paragraph",
    spans = {
      { kind = "text", text = "Imagens: " },
      { kind = "image", alt = "texto alt", src = "a.png" },
      { kind = "text", text = ", " },
      { kind = "image", alt = "ref", src = "img.png" },
      { kind = "text", text = " e " },
      {
        kind = "link",
        children = { { kind = "image", alt = "selo", src = "b.svg" } },
        href = "https://example.com/selo",
      },
      { kind = "text", text = "." },
    },
    src_start = 10,
    src_end = 11,
  },
  {
    kind = "paragraph",
    spans = {
      {
        kind = "text",
        text = "Escape: *não é itálico*, &amp; e <span>tag</span>, ~~tachado~~.",
      },
    },
    src_start = 12,
    src_end = 13,
  },
  {
    kind = "paragraph",
    spans = {
      { kind = "text", text = "Largura e acento: 日本語 " },
      { kind = "strong", children = { { kind = "text", text = "強調" } } },
      { kind = "text", text = " 😀 " },
      { kind = "emphasis", children = { { kind = "text", text = "ñandú" } } },
      { kind = "text", text = " " },
      { kind = "code", text = "ü" },
      { kind = "text", text = " " },
      {
        kind = "link",
        children = { { kind = "text", text = "ação" } },
        href = "https://example.com/ç",
      },
      { kind = "text", text = "." },
    },
    src_start = 14,
    src_end = 15,
  },
  {
    kind = "paragraph",
    spans = {
      { kind = "text", text = "Quebra suave\nna mesma frase e quebra forçada" },
      { kind = "break" },
      { kind = "text", text = "com dois espaços." },
    },
    src_start = 16,
    src_end = 19,
  },
}
