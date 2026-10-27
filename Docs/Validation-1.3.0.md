# Taber 1.3.0 (build 12): candidata em validação

Data: 14/09/2026. Base: `ad544da` (1.2.3/build 11). Esta candidata **não está aprovada para publicação**. A versão em `/Applications/Taber.app` foi preservada. Testes reais usam uma cópia assinada em `/tmp/taber-v130-reviewed/Taber.app`.

## Implementação

- Resolução explícita encontrada/temporariamente indisponível/omitida fora do Space/ausente/ambígua. Consulta AX inicial transitória inicia novas tentativas sem ativar janela irmã às cegas.
- Referências AX por PID, nascimento do processo e CGWindowID, revalidadas antes de uso. Snapshot AX incompleto preserva estratégia de janela previamente confirmada, sem reutilizar foco antigo.
- Preparação do foco antes da ativação; cessão cooperativa (`yieldActivation`) quando Taber está ativo combinada com `.activateIgnoringOtherApps` a partir do painel não-ativador para transições confiáveis entre Spaces e tela cheia. Sem mover Spaces ou emitir saída de tela cheia.
- Transação única cancelável, verificações a cada 200 ms e limite de dois segundos. Ativação do aplicativo não equivale a confirmação de janela específica.
- Player AX conhecido mantém identidade própria e recebe foco. Superfícies CG-only têm resultado distinto quando só a ativação do aplicativo pode ser comprovada.
- Coleta e reconciliação em serviço serial, snapshots publicados no main actor, pedidos coalescidos, eventos AX/Workspace e reconciliação periódica de três segundos. Pausa/suspensão interrompem trabalho periódico.
- Histórico por janela baseado no foco observado, ordem congelada durante o ciclo e seleção preservada por identidade.
- Comandos recebidos durante a coleta inicial são reproduzidos sem perder busca, texto, navegação ou liberação de Command. A limpeza do painel não cancela a transação iniciada no commit.
- Diagnóstico local opt-in em Permissões e sobre; identidades AX opacas e IDs numéricos CG, sem títulos/documentos no arquivo.

Conceitos estudados no `Sanyam-G/switch`, commit `ae1ed9358b26abc8ef6df501a8a86802c577c64a`, foram implementados independentemente. Nenhum código da referência foi incorporado. Sua licença FSL-1.1-MIT não foi tratada como autorização irrestrita para código concorrente.

## Evidências automatizadas

- Typecheck Swift 6 concluído.
- 20 regressões das regras puras e quatro fixtures de elegibilidade passaram.
- Execução principal: 92 XCTest, zero falhas/skips, `Build/Validation/20260914-171745.xcresult`.
- Execução independente: 92 XCTest, zero falhas/skips, `Build/Validation/20260914-171937.xcresult`.
- A revisão independente encontrou cancelamento indevido após commit no cold-start. Corrigido e acrescentada regressão com coordenador, relógio e cancelamento reais injetados; execução independente final: **93 testes aprovados, zero falhas/skips**, `Build/Validation/20260914-172121.xcresult`.
- Build universal arm64/x86_64 gerado e assinatura existente verificada. Artefato regenerado após a última alteração, assinatura verificada novamente e execução confirmada pela UI. SHA-256 do artefato de 14/09 (substituído pelo lote de performance): `9e9b9f380facd0526ccfdf4c81eb40f15669e8f98a6ad157d0341ff15d0a8fac`. Só o artefato aprovado na aceitação poderá ser instalado/publicado.

Os relatórios `.xcresult` e logs em `/tmp` são evidências locais, não arquivos versionados. A tentativa `20260914-122453.xcresult` falhou antes dos casos devido a bloqueio do `testmanagerd` pelo sandbox; não foi contada como teste funcional. As execuções posteriores usaram o acesso necessário e suas contagens foram conferidas pelo `xcresulttool`.

## Evidências no aplicativo real

Confirmados por UI: candidata assinada 1.3.0 em execução, Acessibilidade e Gravação de Tela concedidas, alternador habilitado, controle de diagnóstico e criação do arquivo JSONL funcionando.

Preparadas duas janelas descartáveis A/B no Chrome visitante e vídeo MP4 sintético local. O `Command+Tab` enviado pela ferramenta de controle não abriu o painel nem produziu `panelOpened`/`activation`. O arquivo contém o evento de controle `diagnosticsOpened`, demonstrando que o logger funciona. Isso **não comprova** que o atalho físico falhe, nem que a alternância funcione. Foi solicitada confirmação do teclado físico para separar falha da ferramenta e falha do aplicativo.

## Matriz de aceitação pendente

| Cenário | Repetições exigidas | Estado |
|---|---:|---|
| Duas aplicações | 10 por direção | Não validado |
| Duas janelas do mesmo navegador | 10 por direção | Preparado; não validado |
| Janela minimizada / aplicativo oculto | 10 por direção | Não validado |
| Desktops distintos | 10 por direção | Não validado |
| Tela cheia nativa | 10 por direção | Não validado |
| Vídeo em tela cheia Chrome / Safari | 10 por direção | Vídeo local preparado; não validado |
| Seleção rápida / fechamento durante transição | Caminho real | Cobertura lógica; real pendente |
| P50/P95 antes/depois e abertura com cache P95 ≤100 ms | Medição real | Não medido |

Não converter fixtures nem os tempos do XCTest em latência real do Taber. Não atribuir aprovação ≥9 enquanto existir cenário central sem validação. A revisão independente atribuiu **5,0/10 provisórios — entrega não aprovada**:

| Critério | Pontos | Evidência/limitação |
|---|---:|---|
| Correção funcional e identidade | 3,2/4 | Diff revisado, achados corrigidos e regressões; funcionamento real não demonstrado |
| Validação real | 0/3 | Matriz exigida não completada |
| Robustez e desempenho | 1,0/2 | Cobertura lógica de falhas/cancelamento; P50/P95 reais ausentes |
| Entrega reproduzível | 0,8/1 | Suíte e documentação reproduzidas; aceitação pendente |

A regeneração e abertura do artefato final foram concluídas após essa avaliação; isso não resolve as pendências centrais nem autoriza aumentar a nota. A próxima revisão exige as evidências reais e as medições antes/depois.

## Reprodução e entrega

Execute `zsh Scripts/test.sh --logic-only`, examine o `.xcresult` e execute `zsh Scripts/build-app.sh` com a identidade de assinatura existente. A instalação final usa `zsh Scripts/install-app.sh`, **somente após aprovação**. Após aprovação, commit e push para `origin/main` sem reescrever histórico. Nenhum push/instalação final foi realizado para esta candidata.


Atualização de 17/09: [lote de performance e evidências recentes](Performance-Previews.md), incluindo quatro trocas reais confirmadas. A matriz completa continua pendente.

Atualização de 19/09: [correção da superfície residual do Safari](Safari-Residual-Window.md), com 101 testes independentes aprovados e candidata assinada atualizada. A confirmação do caso real ainda está pendente.

## Reavaliação de 20/09 — `Command-M` imediato

O diagnóstico de uso recebido após os ajustes registrou 17 transações com
`focusObserved` seguido de `activated`, uma solicitação de encerramento pelo
`Command-Q` (`sent: true`), três cancelamentos e uma rejeição
`targetNotFound` para uma janela do Safari. Os cancelamentos podem representar
uma nova seleção; a rejeição não tinha contexto suficiente no registro antigo
para atribuir a causa.

A revisão encontrou uma lacuna concreta compatível com uma minimização seguida
imediatamente de alternância: durante até três segundos o snapshot reaproveitado
pode indicar que a janela é visível, enquanto `Command-M` já removeu a
superfície do WindowServer. O driver deixava de consultar AX nesse caso e
concluía que o alvo não existia. A resolução agora consulta AX antes de concluir
ausência; na confirmação, uma superfície CG ausente só encerra a transação se a
referência AX também se tornar inválida. A regressão do coordenador cobre
snapshot visível com alvo AX atualmente minimizado, restaurado e focado.

Após a alteração, a execução principal e a independente aprovaram **106 testes,
zero falhas e zero skips**: `Build/Validation/20260920-093447.xcresult` e
`Build/Validation/20260920-093605.xcresult`. Também passaram 20 regressões
puras, quatro fixtures de elegibilidade e `git diff --check`. A candidata
assinada foi regenerada, mas não instalada nem publicada.

A revisão independente atribuiu **6,8/10 provisórios**: correção/identidade
3,5/4, validação real 1,2/3, robustez/desempenho 1,2/2 e entrega reproduzível
0,9/1. O limite vem da evidência, não de uma nova falha de implementação: ainda
é necessário testar fisicamente a candidata corrigida com `Command-M` e a
alternância imediata, além da matriz de Spaces, tela cheia nativa, vídeo em
tela cheia e prévias. A suíte com driver simulado valida a transação, mas não
substitui o WindowServer e a Acessibilidade do uso real. Conforme `AGENTS.md`,
esta nota não autoriza substituir `/Applications/Taber.app` nem enviar a
candidata a `origin/main`.

## Atualização de 23/10/2026 — Tela cheia, vídeo em tela cheia e latência de varredura

Diagnóstico ao vivo nos logs unificados (`com.taber.app`) e no WindowServer/SkyLight em MacBook com notch (`screen.frame = 1710×1112`, área abaixo da câmera `1710×1074` em `y = 38`) identificou cinco causas para falhas ao alternar com janela em tela cheia e vídeo reproduzindo:

1. **Geometria fullscreen em telas com notch (`WindowManager.swift`)**: players e janelas em Space fullscreen ficavam com altura `1074` (`38 pt` abaixo do recorte da câmera), excedendo a tolerância fixa de `12 pt` em `isFullScreenWindow` e impedindo o reconhecimento de superfícies destacadas de vídeo (como o player fullscreen do Safari em Space dedicado) e `AXDialog`s de mídia. `isFullScreenWindow` e `coversMostOfScreen` agora contemplam o recorte superior da barra de menu/câmera.
2. **Omissão de janelas fora do Space ativo pelo `kAXWindowsAttribute` (`WindowManager.swift`)**: `liveAccessibilityWindows` complementa `kAXWindowsAttribute` com `kAXFocusedWindowAttribute`, `kAXMainWindowAttribute` e referências válidas do `AXWindowReferenceCache` para `CGWindowID`s vivos do processo.
3. **Timeout de 320 ms por consulta AX a processos sem janelas (`WindowManager.swift`)**: `orderedApplications` filtrava todos os processos em execução (~120 processos `.prohibited`/XPC), estourando o orçamento de 320 ms em toda varredura (`0,324 s`). Restringir a coleta AX a processos com superfícies CG elegíveis, `.regular` ou `.accessory` (quando utilitárias estão ativas) reduziu a varredura real medida para **54,61 ms**.
4. **Foco e ordem de recência durante vídeo em tela cheia (`WindowManager.swift`, `AppDelegate.swift`)**: quando um player fullscreen destacado está `isOnScreen == true` em seu Space e a janela hospedeira do navegador está fora da tela (`Space 1`) mas ainda reportada em `kAXFocusedWindowAttribute`, o foco efetivo é transferido para o player fullscreen visível, `WindowRecencyHistory.current` resolve para o player ativo e `WindowRecencyHistory.ordered` prioriza janelas de outros aplicativos antes da janela hospedeira oculta do mesmo navegador (espelhando o comportamento esperado do `Command + Tab`). Em `NSWorkspace.activeSpaceDidChangeNotification`, o `WindowTrackingService` passa a observar o aplicativo em primeiro plano mesmo sem `applicationUserInfoKey`.
5. **Ativação e confirmação entre Spaces fullscreen e Desktop (`AccessibilityService.swift`, `SwitcherPanelController.swift`)**: `activateApplication()` usa `.activateIgnoringOtherApps` a partir do painel não-ativador do Taber e foca referência AX em cache quando disponível; `confirmation(of:)` reconhece tanto players consolidados (`presentationWindowID`) quanto superfícies CG-only visíveis (`isSurfaceOnScreen(id) == true`); alvos fora do Space temporariamente indisponíveis no AX acionam a ativação do aplicativo na retentativa para iniciar a transição de Space; o `NSPanel` do alternador usa `.popUpMenu` com `.stationary` e `.ignoresCycle` sobre Spaces fullscreen.

Evidências deste lote:
- Typecheck Swift 6 limpo, `git diff --check` sem avisos, **21 verificações de regressão**, **4 fixtures de elegibilidade** e **108 testes XCTest aprovados (0 falhas, 0 skips)** em `Build/Validation/20261022-231711.xcresult`.
- Build Release universal (`arm64` + `x86_64`) gerada e assinada por `Apple Development: samuelhsp1@gmail.com (RZ5743425S)` em `Build/Taber.zip` (`SHA-256: fcdf7b068826a65d1f22725415d312a45687bafc944bf4907b60d78a28fe327e`).

## Atualização de 24/10/2026 — Retorno ao vídeo em tela cheia (Chrome/Safari) e matriz real

Na matriz real de 23/10 a candidata **saía** do vídeo em tela cheia, mas **não voltava** a ele (WebKit 0/10 e Chrome 0/10 no retorno), o mesmo sintoma relatado em YouTube/filmes no Chrome e no Safari. Causas e correções:

1. **Ativação entre Spaces interrompida (`AccessibilityService.swift`)**: quando a superfície do vídeo estava fora da tela, `activateApplication()` usava o pedido do SkyLight e retornava antes de `NSRunningApplication.activate`, de modo que o aplicativo nem sempre chegava à frente e a transição para o Space do vídeo não acontecia. O pedido do SkyLight passa a ser só uma indicação prévia e a ativação normal + foco sempre ocorrem.
2. **Janela hospedeira do vídeo WebKit à frente do aplicativo anterior (`AppDelegate.swift`)**: o `WKFullScreenWindow` aparece no AX como janela padrão **sem título** e sem `presentationWindowID`. `WindowRecencyHistory.ordered` agora também reconhece esse caso e coloca a janela hospedeira (fora da tela, no Desktop) depois do aplicativo anterior; um `Command+Tab` sai do vídeo para o app anterior, como no sistema. Regressão: `testUntitledAXFullScreenVideoPlayerDeprioritizesOffScreenHostWindow`.
3. **Estado depois da animação de Space (`AppDelegate.swift`)**: além da atualização em +50 ms, `activeSpaceDidChange` agenda nova reconciliação em +750 ms, depois dos ~650 ms da animação, em vez de esperar o temporizador de 3 s.

### Evidências

- 21 regressões puras, 4 fixtures de elegibilidade e **112 XCTest aprovados (0 falhas, 0 skips)**: `Build/Validation/20261024-131740.xcresult`. `git diff --check` limpo.
- Build Release universal assinada (`Apple Development: samuelhsp1@gmail.com (RZ5743425S)`), `Build/Taber.zip` SHA-256 `d474b16115422025c449dabced70bc960528d15bc0d9c40b521cd8c6c6f9c3f5`.
- Matriz real com eventos HID (`.cghidEventTap`) num app externo assinado e confiável no AX, com a candidata em `--diagnostics`:

| Cenário | Ida | Volta | P50 / P95 |
|---|---:|---:|---:|
| Duas aplicações | 10/10 | 10/10 | 35,1 / 36,5 ms |
| Minimizada (estável e `Command-M` imediato) e app oculto | 10/10 | 10/10 | 35,7 / 649,5 ms |
| Tela cheia nativa, Spaces distintos (Space preservado 10/10) | 10/10 | 10/10 | 147,0 / 178,4 ms |
| Vídeo em tela cheia WebKit (`WKWebView`) (preservado 10/10) | 10/10 | 10/10 | 145,2 / 150,0 ms |
| Duas janelas do mesmo Chrome | 10/10 | 10/10 | 33,2 / 50,5 ms |
| Chrome, tela cheia de `div` no estilo YouTube, com outra janela Chrome no Desktop | 10/10 | 10/10 | 143,5 / 180,5 ms |
| **Safari do sistema**, tela cheia de `div` no estilo YouTube | 10/10 | 10/10 | 149,5 / 181,1 ms |
| Seleção rápida sobreposta | — | 10/10 | — |

- Abertura com cache (`panelOpened` warm): 170 amostras, P50 2,96 ms, P95 4,01 ms. Captura real de prévias (`thumbnailCaptured`): 65 amostras, P50 37,7 ms, P95 65,3 ms.
- Linha de base 1.2.3 na mesma sessão: falhou em 3/6 trocas simples e não conseguiu sair do vídeo WebKit em tela cheia.
- **Limitação registrada**: no teste de fechar a janela escolhida 12 ms antes de soltar `Command`, o painel já tinha recebido o snapshot atualizado e a seleção passou para a outra janela do mesmo app (identificada explicitamente, `activated`, sem nenhuma rejeição `targetNotFound`). O critério do roteiro ("continuar no app anterior") não foi atendido (0/10). O comportamento escolhido é o mesmo de AltTab e do `Command+Tab` do sistema, que ativam o próximo item visível. Nenhuma janela fora do painel foi ativada.
- O teste usou páginas locais com vídeo MP4, não o YouTube real (rede, anúncios e conta não podem ser reproduzidos de forma determinística). A página imita o YouTube chamando `requestFullscreen()` num contêiner `div`.
