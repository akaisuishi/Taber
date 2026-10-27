# Safari normal identificado como tela cheia — 19/09/2026

Relato ao vivo: Safari aberto fora de tela cheia, marcado como fullscreen pelo Taber, sem alternância para ele. Processo executando no momento do relato: `/Applications/Taber.app`, versão 1.2.3, PID 1240. Não era a candidata 1.3.0.

## Evidências locais

A interface AX consultada pela ferramenta mostrou janela padrão do Safari, barra de abas/ferramentas, controles normais e botão do vídeo para entrar em tela inteira. Nenhuma aba foi fechada ou navegada.

Sonda CG somente leitura, sem títulos/conteúdo, Safari PID 5819:

| ID | On-screen | Layer | Geometria |
|---|---|---|---|
| 1769 | Sim | 0 | x=0, y=30, 2540×1332 |
| 1985 | Não | 0 | x=0, y=0, 2560×1440 |

A segunda superfície, do tamanho do monitor e fora da tela, é compatível com um player residual. A sonda externa não tinha autorização AX (AXtrusted=false, status -25211). Isso não determina a resposta AX recebida pelo Taber autorizado. A associação incorreta foi demonstrada na lógica; sua participação exata na execução instalada não foi instrumentada antes da troca de processo.

## Correção

Removida associação automática de superfície CG-only à única janela AX hospedeira. Tamanho e ausência na lista AX não identificam uma relação entre player e janela normal. Superfícies CG-only só recebem tratamento de player fullscreen com evidência de Space fullscreen e permanecem destinos separados. Players com associação AX preservam o comportamento anterior; seus Spaces são resolvidos pelo ID de apresentação.

Regressão usa host normal + superfície residual fora da tela e verifica identidade, ausência de presentationWindowID, ausência de fullscreen e estratégia raiseWindow, incluindo descoberta até coordenador. Também cobre resposta AX incompleta e player CG fullscreen confirmado sem substituir o host.

## Validação e estado

Revisor independente: **101 XCTest aprovados, zero falhas/skips**, bundle `Build/Validation/20260919-181825.xcresult`; 20 regressões puras e quatro fixtures também passaram. Nenhum defeito relevante adicional identificado no diff.

Candidata assinada 1.3.0/build 12 em `/private/tmp/taber-safari-reviewed/Taber.app`, PID 13466, assinatura verificada. UI confirmou permissões AX/Gravação de Tela concedidas e diagnóstico habilitado. SHA-256 de `Build/Taber.zip`: `374e955cc480e81cc02b0ad582edb73e28b9660a65187401d092943f1a4908ff`.

O atalho enviado por CUA não acionou o alternador nem gerou registro de transação; foi solicitada confirmação pelo teclado físico. **Não declarar o caso real resolvido sem essa confirmação.** Nota independente provisória mantida em **6,0/10**, sem aprovação de publicação. Instalação definitiva e push continuam pendentes conforme AGENTS.md; `/Applications/Taber.app` foi preservado.
