# Taber 1.2.3 — build 11

## Alterações

- Transparência apenas no alternador e menu rápido, com intensidade inicial de 15%, faixa de 0% a 60% e passos de 1%.
- Preferência anterior de ligar/desligar preservada; percentual persistido e normalizado. Alterações atualizam imediatamente o alternador aberto e as prévias, sem alterar seleção ou busca.
- O percentual controla a camada de cor sobre o material desfocado; texto, ícones e miniaturas permanecem opacos. Reduzir Transparência do macOS continua prevalecendo.
- Configurações usam fundo sólido e barra de título padrão, sem transparência.
- Menu rápido limitado pela área útil do monitor do ícone, com espaço para seta/margens e rolagem quando necessário. O tamanho é recalculado ao abrir, mudar o conteúdo ou alterar monitores.

## Validação

- 20 regressões puras, 4 fixtures de elegibilidade e **73 testes lógicos aprovados** em `Build/Validation/20260911-095131.xcresult`.
- Testes novos cobrem migração/persistência/limites do percentual, prioridade da acessibilidade, atualização do alternador aberto, opacidade das configurações e dimensões do menu em telas pequenas e com coordenadas deslocadas.
- **312 renderizações** em `/tmp/taber-1.2.3-visuals`: OFF/0%/15%/60%, três temas, quatro estilos, três tamanhos, menu reduzido e demais cenários de borda. Exemplos representativos foram inspecionados visualmente. Renderizações de views validam layout e aplicação da camada de cor, mas não substituem confirmação de desfoque sobre aplicativos reais.
- Limitações dos testes ao vivo de fullscreen permanecem registradas na entrega 1.2.2. Monitores físicos adicionais não estavam disponíveis para validação.
- O teste de interface existente foi tentado em `Build/Validation/task3-ui.xcresult`, mas o runner expirou ao habilitar o modo de automação; nenhum resultado desse teste foi tratado como aprovação.
- Na versão instalada, a árvore de Acessibilidade e a captura das Configurações confirmaram o novo controle e o fundo sólido. O controle foi exercitado de 15% para 16% e de volta para 15%; a preferência original de transparência ligada foi preservada.
- A janela visitante do Chrome criada para a fixture foi fechada após o teste. A instalação final está assinada, verificada e em execução.
