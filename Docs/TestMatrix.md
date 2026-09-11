# Matriz de alternância — 1.1

Esta matriz registra o resultado das execuções. O contrato de comportamento,
incluindo sinais CG/AX, regras de inclusão, ativação, miniaturas e casos que ainda
dependem de ambiente real, está no
[inventário de cenários de janelas](WindowScenarios.md).
O [checklist de aceitação da refatoração](WindowRefactorAcceptance.md) descreve
a sonda diagnóstica, os motivos tipados e a validação guiada do League sem
atribuir aprovação ao aplicativo ainda não testado.

## Como reproduzir

**zsh Scripts/test.sh** executa as 20 verificações anteriores, quatro fixtures
puras da sonda de elegibilidade, o target de lógica TaberTests e o target
TaberUITests. A opção --logic-only não executa a automação de interface. O
script imprime o diretório temporário com o .xcresult.
Xcode deve ter autorização para automação de interface; não concedemos acesso
silenciosamente. O target lógico compila os mesmos arquivos Swift do produto.

WindowSnapshotSource injeta WindowServer/AX/Spaces; WindowActivationDriving
injeta operações de ativação; ActivationClock controla a restauração atrasada.
O monitor aceita relógio e ativador controlados. O teste de UI usa preferências
isoladas e não instala um segundo monitor de teclado.

## Marco de testes, antes das correções

Execução em 07/09/2026, macOS 26.6.2 arm64:
**27 aprovados + 5 falhas esperadas estritas, 0 falhas inesperadas**.
As 20 verificações antigas também passaram.
Evidência local: /tmp/taber-tests.EUDnzo/Results.xcresult.
Execução consolidada: /tmp/taber-tests.EUDnzo/Complete.xcresult — 34 testes,
29 aprovados e as mesmas 5 falhas esperadas. Inclui medição de performance e
teste real da UI do Taber: quatro seções, fechar/reabrir configurações e encerrar
com os atalhos padrão. Esse teste de UI passou.
Os nomes test01…test32 identificam cada linha no relatório do Xcode.

Todos os resultados da tabela são **automatizados com fixtures**, não ponta a
ponta. Uma aprovação cobre a regra descrita na coluna “cobertura”; não prova o
comportamento integral de um aplicativo de terceiros.

| Nº | Resultado esperado / cobertura automatizada | Marco inicial |
|---|---|---|
| 01 | Sem janelas: ciclo vazio não ativa alvo | Aprovado |
| 02 | Uma célula; dimensões menores nos 4 visuais × 3 tamanhos | Aprovado |
| 03 | Foco AX supera ordem WindowServer | Aprovado |
| 04 | Janela focada prevalece sobre principal | Falha esperada |
| 05 | Chrome comum/anônimo: ID exato seleciona alvo | Aprovado |
| 06 | Safari comum/privado: identidades distintas | Aprovado |
| 07 | Finder: títulos iguais recebem identificação distinta | Aprovado |
| 08 | Geometria igual não apaga janela quando AX falha | Falha esperada |
| 09 | Minimização imediata: estado AX prevalece | Aprovado |
| 10 | Todas minimizadas permanecem disponíveis | Aprovado |
| 11 | Restaurar uma não toca no driver da outra | Aprovado |
| 12 | Restauração antiga não rouba seleção nova | Falha esperada |
| 13 | Aplicativo oculto: resolver antes de ativar | Aprovado |
| 14 | Alvo fechado não ativa outra janela do aplicativo | Falha esperada |
| 15 | ID obsoleto não cai em geometria de substituto | Falha esperada |
| 16 | Space resolvido aparece na descrição | Aprovado |
| 17 | Reordenação recalcula número do Desktop | Aprovado |
| 18 | Sem informação não inventa número; múltiplos Desktops requerem extensão | Parcial |
| 19 | Numeração distinta entre telas | Aprovado |
| 20 | Métricas finitas; desconexão real de monitor depende do ambiente | Parcial |
| 21 | Fullscreen nativo mantém ativação por ID exato | Aprovado |
| 22 | Player Safari: não restaurar janela hospedeira | Aprovado |
| 23 | Player Chrome: associação por documento | Aprovado |
| 24 | Política de auxiliares para Picture-in-Picture | Aprovado |
| 25 | Diálogo com ID próprio não se funde por título | Aprovado |
| 26 | Spotlight, Drive oculto e helpers excluídos | Aprovado |
| 27 | AX indisponível mantém fallback; timeout real depende do aplicativo | Parcial |
| 28 | Seleção independe de miniatura; DRM real depende de conteúdo protegido | Parcial |
| 29 | Acentos, nenhum resultado e busca com Command solto | Aprovado |
| 30 | Tab, inversão, setas por visual e cancelamento | Aprovado |
| 31 | VM/Arc representados pela janela hospedeira, sem janelas internas | Aprovado (simulado) |
| 32 | 200 janelas/100 apresentações mantêm seleção e geração atuais | Aprovado |

O cenário adicional test33RepeatablePerformanceFixture mede 40 varreduras de
200 janelas e 10.000 seleções usando os mesmos dados; não mede latência real do
WindowServer ou ScreenCaptureKit. Resultados antes/depois serão registrados no
relatório final. .xcresult e logs de execução permanecem locais, pois testes
de UI podem registrar a área de trabalho.

## Validação real

Pendente no marco de testes. Chrome, Safari, Finder e TextEdit serão exercitados
somente com janelas descartáveis. Fullscreen protegido, monitores separados,
VM configurada e sessão remota autenticada não serão presumidos disponíveis.
Ausência dessas dependências será explicitada no relatório final.

## Resultado após correções

As cinco falhas esperadas foram removidas e agora passam. A suíte reproduzível
tem 39 aprovações, incluindo S34–S38 para minimização sem superfície CG,
ambiguidade, ausência de janela atual, host fechado e cancelamento de restauração.
S18 agora cobre múltiplos Spaces e todos os Desktops; S20 valida reposicionamento
em retângulos de telas; S32 verifica limite e descarte por geração de capturas.
Essas ampliações continuam sendo automatizadas com fixtures.

O [relatório final](Release-1.1.0.md) registra medições, instalação e limites de
validação ao vivo. A sonda real do Chrome apresentou timeout sem ciclo HID
registrado e **não foi aprovada**. Ela é separada da suíte reproduzível e pode
ser acionada com --live-hid. Não atribuímos aprovação ponta a ponta às simulações.

## Marco da refatoração de janelas e transparência

As fixtures da Task 4 ampliam esta matriz para AX-only, todas minimizadas,
bundle aninhado, políticas `.accessory`/`.prohibited`, renderer CG-only
League-like, superfícies ambíguas, dialog/sheet/utility, conteúdo protegido,
Configurações local e processos técnicos. Também cobrem processo reiniciado,
fallback sem APIs privadas, Command-up perdido, event tap desabilitado,
exclusividade de overlays e precedência de “Reduzir Transparência”.

Execução final em 08/09/2026: 20 regressões puras, 4 fixtures da sonda,
57 testes lógicos e 1 teste de UI aprovados, sem falhas. A suíte lógica inclui
a saída de uma superfície fullscreen sem AX confiável para uma janela de outro
aplicativo/Space e a repetição segura de foco após a transição. Evidência:
`Build/Validation/20260908-182335.xcresult`. O build universal arm64 + x86_64
sem assinatura também passou. A matriz visual produziu 198 imagens em
`/tmp/taber-task4-visuals-final`; combinações representativas ON/OFF dos três temas,
quatro visuais, Configurações e painel rápido foram inspecionadas sem corte ou
perda de contraste. O toggle também foi encontrado e acionado no teste de UI.

O gate repetível de 200 janelas registrou mediana de **1,519 ms**, contra
baseline de 5,568 ms e limite de 6,125 ms (+10%); não houve regressão. A
validação com o League instalado continua **aguardando validação guiada** e segue o
[checklist dedicado](WindowRefactorAcceptance.md#checklist-guiado--league-of-legends).

## Correções 1.2.1–1.2.3

- Finder: 62 testes lógicos aprovados na entrega 1.2.1; inclui AX vazio completo, consulta incompleta, superfícies da área de trabalho, janelas reais minimizadas e renderizadores sem AX.
- Tela cheia: 68 testes lógicos aprovados na 1.2.2; inclui confirmação de destino, cancelamento, timeout, identidade host/player e associação ambígua. O teste real de vídeo no Chrome foi iniciado, mas a captura de retorno ficou preta, portanto o resultado ao vivo é inconclusivo.
- Transparência/menu: 73 testes lógicos aprovados na 1.2.3 e 312 renderizações de fixtures. Inclui 0%, 15%, 60%, OFF, persistência, acessibilidade e menu com altura restrita.
- Ver [1.2.1](Release-1.2.1.md), [1.2.2](Release-1.2.2.md) e [1.2.3](Release-1.2.3.md) para evidências e limitações.
