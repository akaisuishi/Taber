# Taber 1.2.1 — build 9

- Finder sempre passa pela reconciliação de Acessibilidade, mesmo com apenas uma superfície em segundo plano.
- Respostas completas sem janelas removem entradas residuais; consultas incompletas preservam identidades distintas.
- Papéis de área de trabalho e superfícies que não representam janelas são descartados. Janelas reais minimizadas e de outros Spaces permanecem disponíveis.
- Renderizadores customizados continuam aceitos com evidência do WindowServer.
- Alterações locais anteriores da versão 1.2.0 foram preservadas nesta base.

## Validação

- 20 regressões puras e 4 fixtures de elegibilidade aprovadas.
- Testes lógicos aprovados em `Build/Validation/20260910-214432.xcresult`, incluindo cinco novos cenários de Finder/AX.
- A sonda WindowServer funcionou no Mac; a interface confirmou uma janela real do Finder aberta no momento da coleta. A sonda AX avulsa não tem permissão de Acessibilidade, portanto essa coleta não reproduziu conclusivamente a entrada fantasma.
