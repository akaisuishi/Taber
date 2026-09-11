# Taber 1.2.0 — build 8

## Entrega

- Descoberta e ativação de janelas refatoradas conforme o inventário de
  cenários do macOS, incluindo alvos AX-only, renderizadores customizados,
  jogos, múltiplos Spaces e a janela de Configurações do próprio Taber.
- Transparência global disponível em **Configurações > Aparência >
  Transparência** e no painel rápido da barra de menus. A preferência vale para
  os quatro visuais e os temas Original, Dark e Claro; “Reduzir Transparência”
  do macOS continua prevalecendo.
- Correção adicional para sair de aplicativos fullscreen ou que usam uma
  superfície equivalente a fullscreen. Quando o destino está em outro Space,
  o Taber repete uma vez a ativação e o foco da mesma identidade depois do
  início da transição, sem escolher outra janela por aproximação.

## Validação

- 20 verificações puras de regressão e 4 fixtures da política aprovadas.
- 57 testes lógicos aprovados, incluindo dois casos dedicados ao fluxo de saída
  de fullscreen, em `Build/Validation/20260908-182335.xcresult`.
- 198 renderizações de transparência ON/OFF foram repetidas para o build 8 e
  inspecionadas em combinações representativas dos três temas, quatro visuais,
  Configurações e painel rápido, em `/tmp/taber-1.2-visuals`.
- O teste de interface permanece aprovado pela execução anterior. Duas
  tentativas de repetição do build 8 foram inconclusivas porque o runner do
  Xcode expirou ao habilitar o modo de automação, inclusive após encerrar a
  instalação anterior; isso foi registrado como limitação do ambiente, não
  convertido em aprovação do novo build.

O League of Legends não está instalado no ambiente de desenvolvimento. Sua
regra “League-like” está coberta por fixture, mas a partida real continua
dependente da validação guiada descrita em `WindowRefactorAcceptance.md`.
