# Matriz de alternância — 1.1

## Como reproduzir

**zsh Scripts/test.sh** executa as 20 verificações anteriores, o target de lógica
TaberTests e o target TaberUITests. A opção --logic-only não executa a automação
de interface. O script imprime o diretório temporário com o .xcresult.
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
