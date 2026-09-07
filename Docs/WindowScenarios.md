# Mapa de janelas do macOS

Este documento define quais superfícies o Taber trata como janelas de usuário,
como elas são identificadas e qual nível de validação existe. `CG` significa
WindowServer/Core Graphics e `AX`, a árvore de Acessibilidade. Uma fonte não é
considerada verdade absoluta: o inventário final reconcilia as duas.

## Contrato de inclusão

Uma janela entra no alternador quando há evidência de que ela representa uma
superfície com a qual o usuário pode interagir. São evidências fortes um papel
AX de janela, um `CGWindowID` pertencente a um aplicativo do usuário, geometria
útil, associação a um Space e a presença visível ou minimizada. Activation
policy, path do bundle, layer, alpha, título e tamanho são sinais auxiliares;
isoladamente não podem excluir uma janela legítima.

Menus, tooltips, wallpaper, superfícies do Dock, Spotlight, Control Center,
agentes, XPCs, daemons e processos sem janela de usuário não entram. Janelas
auxiliares visíveis entram somente com **Incluir janelas auxiliares** ativo.
Aplicativos fechados ou executados sem janela não são alvos: o Taber traz uma
janela existente para frente, mas não cria uma nova janela nem inicia um app.

## Matriz de cenários

| Cenário | Sinais CG/AX | Inclusão e ativação esperadas | Miniatura | Evidência |
|---|---|---|---|---|
| Janela AppKit/Cocoa padrão | CG layer 0 e `AXStandardWindow` | Uma entrada por identidade; restaurar, focar e elevar via AX | ScreenCaptureKit quando autorizado | Automatizada |
| Várias janelas do mesmo app ou várias instâncias | PIDs/WindowIDs distintos | Preservar cada alvo e a ordem visual; não confundir instâncias com o mesmo bundle | Individual | Automatizada |
| Título vazio, genérico ou repetido; geometria igual | ID/identifier AX prevalecem sobre texto e bounds | Usar nome do app como fallback e sufixo “Janela N”; empate sem identidade nunca escolhe alvo arbitrário | Individual quando houver CG ID | Automatizada |
| Minimizada ainda presente em CG | `isOnScreen=false`, `AXMinimized=true` | Manter na lista, desminimizar e focar somente a selecionada | Placeholder permitido | Automatizada |
| AX-only ou todas as janelas minimizadas sem superfície CG | `kAXWindows` sem CG correspondente | Criar identidade AX segura e restaurar via AX | Indisponível até surgir superfície capturável | Fixture automatizada; ambiente real pendente |
| Aplicativo oculto, Stage Manager ou janela fora da tela | AX/CG válidos, `isOnScreen=false`; Space pode continuar atual | Incluir; distinguir “outro Space” somente quando a associação de Space for conhecida | Pode estar indisponível durante transições | Fixtures parciais; ambiente real pendente |
| Outro Space, todos os Desktops e múltiplos monitores | CG ID mais associação SkyLight e bounds de tela | Incluir e apresentar localização sem inventar número quando a API não responder | Individual quando capturável | Automatizada por fixture; hardware real pendente |
| Fullscreen nativo | Space fullscreen e identidade exata | Focar a janela específica, sem restaurar uma hospedeira incorreta | Normal, salvo conteúdo protegido | Automatizada |
| Fullscreen customizado, player ou jogo | Superfície ocupa a tela; AX pode expor dialog, host ou nada | Consolidar host/player quando a relação for única; caso CG-only, ativar o app apenas se houver um alvo não ambíguo | Pode falhar em DRM/custom renderer | Browser automatizado; jogo em fixture |
| Dialog, modal e sheet | `AXDialog`, `AXSheet` ou relação modal | Entrar como alvo distinto quando for uma janela de usuário focável | Conforme CG ID | Dialog automatizado; sheet a adicionar |
| Palette, floating panel, inspector e Picture-in-Picture | Subrole utility/floating ou layer não padrão | Somente com a opção de auxiliares ativa e enquanto for uma superfície real visível | Quando compartilhável | Fixture parcial |
| Electron, Chromium, WebKit e Catalyst | Árvore AX/CG pode duplicar host e renderer | Reconciliar por ID/identifier/documento; preservar superfícies legítimas não casadas | Conforme captura | Chrome/Safari automatizados; Catalyst pendente |
| Jogo ou renderer customizado | CG legítimo; AX incompleto ou ausente; app pode ser `.accessory`/`.prohibited` | Não excluir pela policy. Separar dono da superfície do app responsável; ativar somente alvo único | Opcional/indisponível | Fixture “League-like”; League real guiado |
| Bundle aninhado/helper dono de janela | Bundle URL contém outro `.app/Contents` | Evidência de janela supera heurística de helper; processos realmente headless continuam fora | Conforme CG ID | Fixture a adicionar |
| X11, Wine, VM e sessão remota | Uma janela macOS hospeda várias janelas convidadas | Alternar a janela hospedeira; não prometer controle das janelas internas | Da hospedeira | VM/remote em fixture; ambiente real pendente |
| Alpha zero, layer não padrão ou janela pequena | Sinais transitórios ou utilitários | AX forte preserva janela; sem AX exigir evidência CG suficiente. Menus/tooltips não passam | Conforme disponibilidade | Fixtures a adicionar |
| Conteúdo protegido/DRM | Janela selecionável, captura negada/vazia | Alternância não depende da miniatura | Placeholder explícito | Lógica automatizada; DRM real pendente |
| Janela fechada, PID reiniciado ou ID obsoleto | Processo/data de lançamento/identidade divergem | Revalidar e abortar sem ativar outra janela | Não aplicável | Automatizada |
| Configurações do Taber | WindowID registrado pelo próprio app | Incluir apenas enquanto aberta/minimizada e ativar diretamente por AppKit | Permitida, sem depender dela | A adicionar |
| Switcher, popover, preview e menus do Taber | IDs/tipos internos registrados | Sempre excluir para evitar recursão | Não aplicável | A adicionar |
| Dock, Spotlight, Control Center, wallpaper e shell | Bundle do sistema, roles técnicos ou desktop layer | Sempre excluir | Não aplicável | Parcialmente automatizada |
| Agente, XPC, daemon ou app sem janela | Sem evidência CG/AX de janela de usuário | Sempre excluir, mesmo que apareça no Monitor de Atividade | Não aplicável | Automatizada e ampliável |
| Event tap interrompido, Secure Input ou Command-up perdido | Evento de tap desabilitado ou flags globais sem Command | Ocultar/cancelar em falha do tap; finalizar com segurança quando Command já foi solto | Não aplicável | A adicionar |

## Identidade e fallback

A ordem de reconciliação é: `CGWindowID` exato, identifier AX único e, por fim,
uma pontuação de documento, título e geometria que só é aceita quando há um
vencedor único. Uma janela AX-only usa PID, data de lançamento, identifier AX e
um fingerprint local; o ordinal é apenas desempate dentro do snapshot.

Quando AX não consegue distinguir várias superfícies CG do mesmo processo, o
Taber pode oferecer um único alvo de aplicativo, mas nunca várias entradas que
ativariam a mesma janela por acaso. Antes de qualquer ação, PID, bundle e data
de lançamento são revalidados.

## League of Legends

O League não está instalado no ambiente de desenvolvimento atual. A cobertura
automatizada deve reproduzir os riscos observados: renderer em bundle aninhado,
activation policy não regular, fullscreen CG sem `kAXWindows` completo e
ativação por aplicativo. Isso não será descrito como aprovação ponta a ponta.

A validação guiada deve exercitar cliente e partida, modos janela e fullscreen,
confirmar presença no alternador, retorno do foco e registrar a decisão de
elegibilidade/estratégia de ativação. Os logs permanecem locais.

## Níveis de evidência

- **Automatizada**: XCTest ou regressão pura determinística.
- **Fixture automatizada**: reproduz o formato técnico, não o aplicativo real.
- **Ambiente real pendente**: depende de app, hardware, Space ou permissão que
  não está disponível na execução automatizada.
- **Guiada**: checklist manual acompanhado do diagnóstico do Taber.

Consulte `TestMatrix.md` para os resultados reproduzíveis e os limites dos
testes ao vivo.
