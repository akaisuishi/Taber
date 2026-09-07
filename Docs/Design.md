# Interface nativa refinada

A identidade mantém o nome e o ícone do Taber. Superfícies discretas, fonte de
sistema e seleção com preenchimento e contorno substituem o excesso de efeitos.
As configurações usam sidebar persistente; o clique esquerdo na barra de menus
abre um painel rápido e o direito preserva um menu nativo.

## Sistema visual

- `TaberThemePalette`: Original grafite, Dark neutro e Claro suave.
- `TaberChoiceSurface`: seleção compartilhada com contorno mais forte quando
  Aumentar Contraste está ativo.
- `TaberSurfaceBackground`: material nativo, opaco com Reduzir Transparência.
- `SwitcherMetrics`: conteúdo e janela compartilham as mesmas métricas.
- Navegação sem animação de escala ou deslocamento; captura não participa do
  cálculo de tamanho. Assim, Reduzir Movimento não depende de efeitos especiais.
- Ícones representam janelas, com título adicional; Fluxo omite a fila com uma
  janela. Busca e rodapé têm o mesmo tratamento nos quatro modos.

## Evidências visuais

`zsh Scripts/render-visuals.sh /tmp/taber-visuals` renderiza fixtures locais:
147 imagens incluindo os quatro visuais, três temas, três tamanhos, 1/3/12
janelas, títulos longos, quatro seções das configurações, painel rápido,
buscas vazias e área pequena de 640 × 360 pontos.
Foram inspecionadas amostras dos quatro visuais, janela única, títulos longos,
configurações e painel rápido. Renderização não equivale a teste ponta a ponta.
As imagens do README contêm exclusivamente conteúdo fictício, sem capturas de
janelas pessoais. A prévia nas configurações também não captura dados reais.
