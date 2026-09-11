# Taber 1.2.2 — build 10

- Ativação distingue pedido enviado, destino confirmado, cancelamento, destino desaparecido e tempo limite.
- Confirmações e tentativas a cada 200 ms, limitadas por prazo de dois segundos e dez verificações; novas seleções invalidam callbacks anteriores.
- Foco confirma a identidade AX, processo em primeiro plano e visibilidade da superfície. Falhas transitórias AX não são interpretadas como janela fechada durante a confirmação.
- Tela cheia nativa usa AXFullScreen/Spaces; geometria de janela maximizada não determina esse estado.
- Apresentações de navegador mantêm IDs separados para host e player. A ativação não restaura a janela hospedeira nem envia comandos de saída de tela cheia.
- Players ambíguos não são associados à janela focada apenas por proximidade ou ordem.

## Validação

- 20 regressões puras, 4 fixtures de elegibilidade e 68 testes lógicos aprovados em `Build/Validation/20260911-063250.xcresult`.
- Testes novos cobrem confirmação tardia, limite de tentativas, fechamento do destino, fullscreen AX e associação inequívoca/ambígua de player.
- Build universal assinada instalada em `/Applications/Taber.app`.
- Chrome visitante abriu um vídeo local gerado e confirmou modo tela cheia na árvore de Acessibilidade. A alternância foi exercitada, mas a captura visual de retorno veio preta: esse cenário ao vivo permanece inconclusivo. Safari, múltiplos monitores e sites com reprodução protegida não foram validados ao vivo.
