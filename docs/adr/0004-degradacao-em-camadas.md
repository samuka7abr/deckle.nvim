# ADR-0004 — Degradação em camadas, com camada 0 sempre funcional

**Status:** aceito · **Data:** 2026-09-06

## Contexto

Plugins de preview de Markdown costumam assumir o ambiente do autor: protocolo gráfico
do terminal, Node instalado, ImageMagick, outros plugins. Quem não tem, não usa.

O deckle é para a comunidade, então o alvo é o setup mais pobre plausível: Neovim numa
sessão SSH, dentro do tmux, num terminal sem protocolo gráfico, sem Node, sem nada.

## Decisão

Quatro camadas. Cada uma funciona sozinha; capacidades são detectadas em runtime.

| Camada | Requisito | Mermaid | Imagens |
|---|---|---|---|
| 0 | só Neovim | código cru | texto alternativo |
| 1 | + `deckle_native` | arte Unicode/ASCII | texto alternativo |
| 2 | + protocolo gráfico | arte Unicode/ASCII | imagem real |
| 3 | + `mmdc` (opcional) | imagem rasterizada | imagem real |

## Razão

A camada 1 — o alvo principal — funciona em **qualquer terminal**, porque a saída é
texto. Isso inverte a suposição usual, em que gráficos de terminal são o caminho feliz e
o resto é fallback. Aqui o texto é o caminho feliz, e gráficos são bônus.

A camada 0 existe porque é gratuita: `require` de um `.so` ausente falha de forma
capturável ([V4](../validation.md#v4--binário-ausente-degrada-de-forma-capturável)),
então o plugin carrega e funciona mesmo sem binário nenhum. Um usuário numa plataforma
sem build pré-compilado ainda tem um preview de Markdown utilizável.

Isso também torna a instalação à prova de falhas: se o download do binário cair, o plugin
não quebra — perde uma feature.

## Consequências

- Cada feature que dependa de capacidade externa precisa de um caminho de degradação
  explícito e testado. Não vale "provavelmente funciona".
- `:checkhealth deckle` precisa dizer em que camada o usuário está e o que falta para
  subir — senão a degradação silenciosa vira bug reportado.
- A detecção de capacidade de terminal é notoriamente traiçoeira (tmux, SSH, multiplexers
  que mentem). Padrão conservador: na dúvida, camada mais baixa.
