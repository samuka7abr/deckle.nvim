--- Versão do plugin. É a única fonte: o instalador (`deckle.install`) usa este valor para
--- montar a URL da release (`v<versão>`) e para saber se o binário instalado ainda serve, e a
--- CI de release confere que a tag empurrada (`v0.3.0`, `v0.3.0-rc`) bate com ele.
---
--- Constante em Lua, e não um arquivo `VERSION`, porque o plugin pode estar em qualquer lugar
--- do `runtimepath` e um `require` acha este módulo sem adivinhar caminho.
return "0.3.0"
