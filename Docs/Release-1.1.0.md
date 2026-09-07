# Taber 1.1.0 — build 7

## Entrega

- Interface nativa refinada: sidebar, painel rápido na barra de menus e quatro
  alternadores. Nome, logo, temas, tamanhos e preferências existentes preservados.
- Foco AX separado de janela principal (S04).
- Janelas com título/geometria iguais preservadas no fallback (S08).
- Identidade revalidada antes da ativação, inclusive fullscreen de conteúdo;
  processo encerrado, ID divergente e correspondência ambígua não ativam outro
  alvo (S14, S15, S35, S37).
- Restauração atrasada vinculada à seleção atual, cancelada ao começar outro
  ciclo e revalidada antes de repetir (S12, S38).
- Minimizadas expostas apenas por AX durante uma transição são recuperadas
  quando o aplicativo possui outra superfície conhecida (S34). Sem janela
  atual, o primeiro alvo não é pulado (S36).
- Associação de player exige host único/documento, sem escolher uma janela
  arbitrária. Estado minimizado do host é preservado (S22, S23, S35).
- Múltiplos Spaces, todos os Desktops e associação à tela são representados;
  mudanças de monitor reposicionam o painel (S18–S20).
- Eventos encaminhados à fila principal em ordem; resultados de captura
  cancelados/obsoletos descartados. Máximo de seis capturas simultâneas,
  cache de 48 imagens/128 MiB e reutilização curta (S30, S32).
- Leituras AX agrupadas, timeout de 40 ms por mensagem e orçamento de
  reconciliação de 120 ms por aplicativo / 320 ms por varredura. Esse orçamento
  é cooperativo, não uma garantia de tempo real do macOS; o fallback preserva
  candidatas quando a leitura fica incompleta.

## Resultados

20 verificações anteriores aprovadas. A suíte reproduzível do Xcode passou
com **39 testes: 38 de lógica/integração controlada e 1 de interface real**,
sem falhas esperadas ou inesperadas. O teste real da UI percorreu as quatro
seções e validou fechar, reabrir e encerrar por atalhos padrão.

Foram geradas 147 imagens com conteúdo fictício, abrangendo 4 visuais × 3 temas
× 3 tamanhos, contagens 1/3/12, títulos longos, busca vazia e área de 640 × 360.
Amostras de cada visual e casos de borda foram inspecionadas. As propriedades
de acessibilidade são lidas do sistema; não alteramos as preferências globais
do usuário para produzir as imagens.

Relatórios locais (não versionados, pois podem conter imagens da área de trabalho):

- Build/Validation/Final.xcresult — 39 aprovados.
- Build/Validation/Acceptance.xcresult — repetição de aceitação.
- Build/Validation/Visuals — 147 renderizações fictícias.
- Build/Validation/LiveChrome.xcresult — sonda ambiental, **não aprovada**.

## Limites da validação real

A instalação assinada foi aberta e confirmou Acessibilidade e Gravação de Tela
concedidas. Foram criadas duas janelas locais de visitante do Chrome, sem
utilizar um perfil pessoal. A sonda de teclado do Xcode apresentou timeout:
não houve ciclo registrado no monitor HID do Taber durante a injeção do teste.
Isso não valida a troca A/B nem demonstra, por si só, falha na identidade AX.
O resultado foi mantido, não convertido em aprovação.

A sonda fica separada em LiveHIDIntegrationTests e pode ser executada com
**zsh Scripts/test.sh --live-hid**, com as fixtures abertas e a instalação ativa.
Ela não faz parte das 39 aprovações. O caminho HID real ainda precisa de uma
verificação com teclado físico.

Não foram concluídos testes ponta a ponta com Finder, TextEdit, Safari privado,
vídeo fullscreen/DRM, monitor desconectado, múltiplas telas, Spaces rearranjados,
VM configurada ou sessão remota autenticada. Suas regras estão cobertas em
graus diferentes pelas fixtures da matriz; isso não substitui validação real.
Nenhum aplicativo foi baixado. As duas janelas de visitante foram fechadas.

## Desempenho

Mesma máquina e fixture isolada, Debug arm64, três repetições em cada versão:
40 varreduras de 200 janelas e 10.000 seleções. Medianas:

| Medida | Antes (affc437) | Depois |
|---|---:|---:|
| Varredura de 200 janelas | 5,568 ms | 5,566 ms |
| 10.000 seleções | 4,547 ms | 4,461 ms |
| CPU do trecho medido | 131,506 ms | 137,969 ms |
| Pico de memória do processo | 41,304 MB | 41,271 MB |

Sem regressão repetível acima de 10% nessa fixture. A primeira comparação de
memória misturava a suíte completa com um teste isolado; foi descartada e
repetida com o mesmo escopo. Esses números não representam a latência ponta a
ponta do teclado nem de capturas reais. O painel não espera pelas miniaturas.
Evidências: BaselineRepeat.xcresult e FinalRepeat.xcresult em Build/Validation.

## Instalação e recuperação

Versão universal x86_64 + arm64 em /Applications/Taber.app, assinatura estrita
validada, bundle com.taber.app e mesma equipe de desenvolvimento.
Build/Taber.zip contém a distribuição; Build/Taber-previous.zip guarda a cópia
anterior à atualização. A assinatura preservada não dispensa o macOS de
revalidar permissões conforme suas próprias regras.
