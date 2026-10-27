# Otimizações de alternância e prévias — 17/09/2026

Lote integrado à candidata 1.3.0/build 12. A aceitação real da candidata continua pendente; este documento não afirma um ganho percentual ou P95 que não foi medido.

## Alterações

- O painel usa o snapshot disponível antes de solicitar uma atualização de janelas. A coleta pedida pela abertura é adiada para depois da apresentação.
- Capturas de imagem limitadas a três simultâneas. Excedentes aguardam por continuação assíncrona, em vez de receberem “indisponível” ao atingir o limite antigo de seis.
- Consultas ao catálogo e a tentativa adicional para janelas recém-abertas não ocupam os slots de screenshot. O catálogo compartilhado usa identificador de operação para que cancelamentos não apaguem uma consulta mais recente.
- Pedidos simultâneos da mesma identidade/tamanho compartilham uma captura. O tamanho é arredondado em blocos de 32 pontos, evitando recaptura por pequenas variações de layout.
- Cache limitado a 48 imagens/128 MiB; imagens de até 1,5 segundo dispensam recaptura. Imagens de até 30 segundos podem aparecer imediatamente enquanto a atualização ocorre. Falha temporária mantém uma imagem válida; perda de permissão prevalece sobre o cache.
- Identidade do cache e da tarefa visual inclui nascimento do processo e player de vídeo. A captura usa o ID do player quando presente.
- Fechar o painel invalida a geração, libera pedidos enfileirados e cancela tarefas pendentes. Tarefas canceladas não iniciam nova consulta ao catálogo.

## Evidências

Execução principal: **99 XCTest aprovados, zero falhas/skips**, confirmados pelo `xcresulttool` em `Build/Validation/20260917-212752.xcresult`. Ambiente dessa execução: macOS 27.0 (26A428), arm64. Também passaram 20 regressões puras e quatro fixtures de elegibilidade.

Os novos testes exercitam o serviço real com uma fonte de imagem sintética injetada:

- Dois pedidos concorrentes e 100 leituras subsequentes do cache produzem uma única chamada à fonte de captura; expirar o período fresco provoca atualização.
- Doze destinos diferentes terminam sem descartar pedidos, com pico máximo de três capturas.
- Três consultas de catálogo suspensas não impedem a captura de um quarto destino disponível.
- Cobertura de troca de geração, expiração do cache, perda de permissão e mudança de identidade do player.

Esses números medem chamadas/concorrência da implementação, **não a latência do ScreenCaptureKit real**. P50/P95, uso de GPU/energia e a matriz física de alternância/tela cheia continuam sem validação. Não há base para afirmar que o P95 real já atende 100 ms.

O revisor independente encontrou e acompanhou correções de identidade da tarefa visual, atualização de catálogo ausente, preservação de imagem durante falhas e espera do catálogo ocupando slots. Execução independente final: **99 aprovados, zero falhas/skips**, `Build/Validation/20260917-212858.xcresult`. Nenhum defeito relevante adicional identificado na revisão do diff.

Build assinado universal usa a identidade existente. A checagem de arquiteturas em `Scripts/build-app.sh` passou a ler `lipo -archs` e exigir explicitamente arm64 e x86_64. A instalação publicada e o envio a `origin/main` permanecem condicionados à aprovação definida em `AGENTS.md`.


## Amostra real inicial

Na candidata otimizada, quatro aberturas com cache registradas pelo próprio Taber tiveram P50 de **2,93 ms** e P95 de **3,80 ms** (percentil por posto mais próximo). Quatro trocas tiveram confirmação AX do destino, P50 de **223,37 ms** e P95 de **229,92 ms**; esse intervalo inclui a espera de 200 ms até a primeira confirmação. Não ocorreram rejeições nessas quatro transações.

Amostras espontâneas, painel com duas janelas, sem controle dos cenários/estilos. Elas não são a matriz de dez repetições por direção, não medem tempo de captura de prévias e não fornecem uma comparação antes/depois. Não extrapolar seu P95 para toda a carga de uso.

Proveniência: processo 8644, `/private/tmp/taber-perf-reviewed/Taber.app`, assinatura verificada; registro temporário `Taber-Diagnostics-8644.jsonl`. Artefato final `Build/Taber.zip`, SHA-256 `f44ac87bfb6716ed7fe10d0ab2e5becd9a787f38f65bb44d49130367bdf41679`. A cópia temporária otimizada está em execução; a instalação publicada permanece preservada.

Reavaliação independente após conferir as quatro amostras: **6,0/10 provisórios, sem aprovação de entrega**. Distribuição: correção/identidade 3,4/4; validação real 0,5/3; robustez/desempenho 1,2/2; reprodução 0,9/1. O P95 de quatro amostras corresponde ao maior valor observado e o cronômetro de abertura não comprova apresentação completa dos pixels na tela. Persistem as pendências da matriz e do ScreenCaptureKit real; nenhuma publicação ou substituição da instalação estável foi realizada.
